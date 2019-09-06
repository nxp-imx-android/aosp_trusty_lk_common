/*
 * Copyright (c) 2014 Travis Geiselbrecht
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
#include <assert.h>
#include <err.h>
#include <kernel/mutex.h>
#include <kernel/vm.h>
#include <lib/console.h>
#include <rand.h>
#include <string.h>
#include <trace.h>

#include "vm_priv.h"

#define LOCAL_TRACE 0

static struct list_node aspace_list = LIST_INITIAL_VALUE(aspace_list);
static mutex_t vmm_lock = MUTEX_INITIAL_VALUE(vmm_lock);

vmm_aspace_t _kernel_aspace;

static void dump_aspace(const vmm_aspace_t* a);
static void dump_region(const vmm_region_t* r);

void vmm_init_preheap(void) {
    /* initialize the kernel address space */
    strlcpy(_kernel_aspace.name, "kernel", sizeof(_kernel_aspace.name));
    _kernel_aspace.base = KERNEL_ASPACE_BASE;
    _kernel_aspace.size = KERNEL_ASPACE_SIZE;
    _kernel_aspace.flags = VMM_ASPACE_FLAG_KERNEL;
    list_initialize(&_kernel_aspace.region_list);

    arch_mmu_init_aspace(&_kernel_aspace.arch_aspace, KERNEL_ASPACE_BASE,
                         KERNEL_ASPACE_SIZE, ARCH_ASPACE_FLAG_KERNEL);

    list_add_head(&aspace_list, &_kernel_aspace.node);
}

void vmm_init(void) {}

static inline bool range_contains_range(vaddr_t range_base,
                                        size_t range_size,
                                        vaddr_t query_base,
                                        size_t query_size) {
    vaddr_t range_last;
    vaddr_t query_last;

    ASSERT(range_size > 0);
    ASSERT(query_size > 0);

    ASSERT(!__builtin_add_overflow(range_base, range_size - 1, &range_last));
    ASSERT(!__builtin_add_overflow(query_base, query_size - 1, &query_last));

    return range_base <= query_base && query_last <= range_last;
}

static inline bool is_inside_aspace(const vmm_aspace_t* aspace, vaddr_t vaddr) {
    DEBUG_ASSERT(aspace);
    return range_contains_range(aspace->base, aspace->size, vaddr, 1);
}

static bool is_region_inside_aspace(const vmm_aspace_t* aspace,
                                    vaddr_t vaddr,
                                    size_t size) {
    DEBUG_ASSERT(aspace);
    return range_contains_range(aspace->base, aspace->size, vaddr, size);
}

static bool is_inside_region(const vmm_region_t* r, vaddr_t vaddr) {
    DEBUG_ASSERT(r);
    return range_contains_range(r->base, r->size, vaddr, 1);
}

static bool is_range_inside_region(const vmm_region_t* r,
                                   vaddr_t vaddr,
                                   size_t size) {
    DEBUG_ASSERT(r);
    return range_contains_range(r->base, r->size, vaddr, size);
}

static size_t trim_to_aspace(const vmm_aspace_t* aspace,
                             vaddr_t vaddr,
                             size_t size) {
    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(is_inside_aspace(aspace, vaddr));

    if (size == 0)
        return size;

    size_t offset = vaddr - aspace->base;

    // LTRACEF("vaddr 0x%lx size 0x%zx offset 0x%zx aspace base 0x%lx aspace
    // size 0x%zx\n",
    //        vaddr, size, offset, aspace->base, aspace->size);

    if (offset + size < offset)
        size = ULONG_MAX - offset - 1;

    // LTRACEF("size now 0x%zx\n", size);

    if (offset + size >= aspace->size - 1)
        size = aspace->size - offset;

    // LTRACEF("size now 0x%zx\n", size);

    return size;
}

static vmm_region_t* alloc_region_struct(const char* name,
                                         vaddr_t base,
                                         size_t size,
                                         uint flags,
                                         uint arch_mmu_flags) {
    DEBUG_ASSERT(name);

    vmm_region_t* r = calloc(1, sizeof(vmm_region_t));
    if (!r)
        return NULL;

    strlcpy(r->name, name, sizeof(r->name));
    r->base = base;
    r->size = size;
    r->flags = flags;
    r->arch_mmu_flags = arch_mmu_flags;
    list_initialize(&r->page_list);

    return r;
}

/* add a region to the appropriate spot in the address space list,
 * testing to see if there's a space */
static status_t add_region_to_aspace(vmm_aspace_t* aspace, vmm_region_t* r) {
    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(r);

    LTRACEF("aspace %p base 0x%lx size 0x%zx r %p base 0x%lx size 0x%zx\n",
            aspace, aspace->base, aspace->size, r, r->base, r->size);

    /* only try if the region will at least fit in the address space */
    if (r->size == 0 || !is_region_inside_aspace(aspace, r->base, r->size)) {
        LTRACEF("region was out of range\n");
        return ERR_OUT_OF_RANGE;
    }

    vaddr_t r_end = r->base + (r->size - 1);

    /* does it fit in front */
    vmm_region_t* last;
    last = list_peek_head_type(&aspace->region_list, vmm_region_t, node);
    if (!last || r_end < last->base) {
        /* empty list or not empty and fits before the first element */
        list_add_head(&aspace->region_list, &r->node);
        return NO_ERROR;
    }

    /* walk the list, finding the right spot to put it */
    list_for_every_entry(&aspace->region_list, last, vmm_region_t, node) {
        /* does it go after last? */
        if (r->base > last->base + (last->size - 1)) {
            /* get the next element in the list */
            vmm_region_t* next = list_next_type(
                    &aspace->region_list, &last->node, vmm_region_t, node);
            if (!next || (r_end < next->base)) {
                /* end of the list or next exists and it goes between them */
                list_add_after(&last->node, &r->node);
                return NO_ERROR;
            }
        }
    }

    LTRACEF("couldn't find spot\n");
    return ERR_NO_MEMORY;
}

/*
 *  Try to pick the spot within specified gap
 *
 *  Arch can override this to impose it's own restrictions.
 */
__WEAK vaddr_t arch_mmu_pick_spot(arch_aspace_t* aspace,
                                  vaddr_t base,
                                  uint prev_region_arch_mmu_flags,
                                  vaddr_t end,
                                  uint next_region_arch_mmu_flags,
                                  vaddr_t alignment,
                                  size_t size,
                                  uint arch_mmu_flags) {
    /* just align it by default */
    return align(base, alignment);
}

/**
 * next_spot() - Finds the next valid mapping location in a range
 * @low:            Lowest virtual address available for use
 * @high:           Highest virtual address available for use
 * @align:          Virtual address alignment requested
 * @size:           Size of region requested
 * @arch_mmu_flags: Flags to pass to the mmu in case of restrictions.
 * @out:            Output parameter for the base of a range matching the
 *                  requirements, of size @size. Only valid if next_spot()
 *                  returns true.
 *
 * Finds the lowest region available in a range subject to alignment, size,
 * and MMU constraints.
 *
 * Return: Whether a region was found. If false, *@out is invalid. If
 *         true, *@out is the base of a legal range to map at.
 */
static inline bool next_spot(arch_aspace_t* aspace,
                             uint prev_region_arch_mmu_flags,
                             uint next_region_arch_mmu_flags,
                             vaddr_t low,
                             vaddr_t high,
                             vaddr_t align,
                             size_t size,
                             uint arch_mmu_flags,
                             vaddr_t* out) {
    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(out);

    vaddr_t candidate = arch_mmu_pick_spot(
            aspace, low, prev_region_arch_mmu_flags, high,
            next_region_arch_mmu_flags, align, size, arch_mmu_flags);

    if ((candidate < low) || (candidate > high)) {
        /* arch_mmu_pick_spot sent the base address out of range */
        return false;
    }

    vaddr_t candidate_end;
    if (__builtin_add_overflow(candidate, size - 1, &candidate_end)) {
        /* Virtual address region would wrap around */
        return false;
    }

    if (candidate_end > high) {
        /* Virtual address stretches out of range */
        return false;
    }

    *out = candidate;
    return true;
}

/**
 * extract_gap() - Finds the gap between two used regions
 * @aspace:   The address space we are working in
 * @low:      The lower virtual region. May be null to indicate the area below
 *            the first region.
 * @high:     The higher virtual region. May be null to indicate the area above
 *            the last region.
 * @gap_low:  Output parameter for the lowest open address.
 * @gap_high: Output parameter for the highest open address.
 *
 * Return: Whether a gap was found. If the return value is false, the output
 *         parameters may be invalid. If true, all addresses between
 *         *@gap_low and *@gap_high inclusive are unmapped.
 */
static inline bool extract_gap(vmm_aspace_t* aspace,
                               vmm_region_t* low,
                               vmm_region_t* high,
                               vaddr_t* gap_low,
                               vaddr_t* gap_high) {
    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(gap_low);
    DEBUG_ASSERT(gap_high);
    DEBUG_ASSERT(aspace->size != 0);

    if (low) {
        if (__builtin_add_overflow(low->base, low->size, gap_low)) {
            /* No valid address exists above the low region */
            return false;
        }
    } else {
        *gap_low = aspace->base;
    }

    if (high) {
        if ((*gap_low) == high->base) {
            /* No gap available */
            return false;
        }
        *gap_high = high->base - 1;
    } else {
        *gap_high = aspace->base + (aspace->size - 1);
    }

    return true;
}

/**
 * scan_gap() - Searches between two vm regions for usable spots
 * @aspace:         The address space to search in
 * @low:            The vm region below the search area. May be null to
 *                  indicate the bottom of the address space.
 * @high:           The vm region above the search area. May be null to
 *                  indicate the top of the address space.
 * @alignment:      The required alignment for the new region
 * @size:           How large the new region needs to be
 * @arch_mmu_flags: Architecture specific MMU flags for the new region
 *
 * Finds the number of different candidate offsets for a new region to be
 * created between two others.
 *
 * The result can be higher than reality if arch_mmu_pick_spot() employs exotic
 * requirements, but any value less than the return of scan_gap() will still
 * be valid for spot_in_gap().
 *
 * Return: The number of different places the region could be created within
 *         the gap.
 */
static inline size_t scan_gap(vmm_aspace_t* aspace,
                              vmm_region_t* low,
                              vmm_region_t* high,
                              vaddr_t alignment,
                              size_t size,
                              uint arch_mmu_flags) {
    vaddr_t low_addr;
    vaddr_t high_addr;
    if (!extract_gap(aspace, low, high, &low_addr, &high_addr)) {
        /* There's no gap, so there are no available positions */
        return 0;
    }

    uint low_flags = low ? low->arch_mmu_flags : ARCH_MMU_FLAG_INVALID;
    uint high_flags = high ? high->arch_mmu_flags : ARCH_MMU_FLAG_INVALID;

    vaddr_t first_base;
    arch_aspace_t* arch_aspace = &aspace->arch_aspace;
    if (!next_spot(arch_aspace, low_flags, high_flags, low_addr, high_addr,
                   alignment, size, arch_mmu_flags, &first_base)) {
        /*
         * We couldn't find a first place, so there are no available
         * positions.
         */
        return 0;
    }

    /* Estimate that the last position will be the last page aligned slot */
    vaddr_t final_base = round_down(high_addr - (size - 1), PAGE_SIZE);
    /* If we can't map at that address, shrink it by a page each time. */
    while (!next_spot(arch_aspace, low_flags, high_flags, final_base, high_addr,
                      alignment, size, arch_mmu_flags, &final_base)) {
        if ((final_base - first_base) < PAGE_SIZE) {
            /* There's only one location available in the region. */
            break;
        }
        final_base -= PAGE_SIZE;
    }

    /*
     * first_base and final_base now point to the lower and upper mapping
     * bounds.
     * We assume that every page in between would be a legal mapping. If it
     * would not, the worst consequence will be having less randomness than
     * expected since we know all addresses in the range will have a
     * valid next_spot().
     */

    return ((final_base - first_base) >> PAGE_SIZE_SHIFT) + 1;
}

/**
 * spot_in_gap() - Pick a specific available mapping range
 * @aspace:         The address space in which the mapping will take place
 * @low:            The lower virtual region. May be null to indicate the
 *                  area below the first region.
 * @high:           The higher virtual region. May be null to indicate the
 *                  area above the last region.
 * @align:          The requested alignment of the region
 * @size:           The requested size of the region
 * @arch_mmu_flags: The requested MMU flags (RWX etc)
 * @index:          Which possibility to map the region at. This value must
 *                  be less than the value returned by scan_gap() for the
 *                  same query.
 *
 * spot_in_gap() picks one of several possible regions within a gap, using the
 * provided index to select which one.
 *
 * This function is intended to be used in concert with scan_gap().
 * After running scan_gap(), the size returned will be a max (exclusive) for
 * the value of @index to this function, which should then not fail.
 *
 * Return: The virtual address that the mapping should be performed at.
 */
static inline vaddr_t spot_in_gap(vmm_aspace_t* aspace,
                                  vmm_region_t* low,
                                  vmm_region_t* high,
                                  vaddr_t align,
                                  size_t size,
                                  uint arch_mmu_flags,
                                  size_t index) {
    vaddr_t low_addr;
    vaddr_t high_addr;
    if (!extract_gap(aspace, low, high, &low_addr, &high_addr)) {
        panic("spot_in_gap() called on a 0-size region\n");
    }

    uint low_flags = low ? low->arch_mmu_flags : ARCH_MMU_FLAG_INVALID;
    uint high_flags = high ? high->arch_mmu_flags : ARCH_MMU_FLAG_INVALID;

    vaddr_t base;
    arch_aspace_t* arch_aspace = &aspace->arch_aspace;
    if (!next_spot(arch_aspace, low_flags, high_flags, low_addr, high_addr,
                   align, size, arch_mmu_flags, &base)) {
        panic("spot_in_gap() called on a region with no available mappings\n");
    }

    base += index * PAGE_SIZE;

    if (!next_spot(arch_aspace, low_flags, high_flags, base, high_addr, align,
                   size, arch_mmu_flags, &base)) {
        panic("spot_in_gap() with an index with no mapping option\n");
    }

    return base;
}

/**
 * alloc_spot() - Find a place in the address space for a new virtual region
 * @aspace:         The address space to search within
 * @size:           How large of a spot is required
 * @align_pow2:     Alignment requirements for the gap in bits
 * @arch_mmu_flags: Architecture-specifc MMU flags (RWX etc)
 * @before:         Optional pointer to record the list node which occurred
 *                  prior to the spot we are returning to make list insertion
 *                  easier. If null, no write will occur. If the insertion is
 *                  at the beginning of the address space, the list header
 *                  will be written. This output is only valid if a value
 *                  other than -1 was returned.
 *
 * Finds a space in the virtual memory space which is currently unoccupied,
 * is legal to map according to the MMU, is at least as large as @size,
 * and aligned as @align_pow2.
 *
 * If ASLR is enabled, this spot will also be *randomized* from amongst all
 * legal positions.
 * If ASLR is disabled, it will bias towards the lowest legal virtual address.
 *
 * This function does not actually mutate the aspace and reserve the region.
 * That is the responsibility of the caller.
 *
 * Return: The value of the first address for the new region if one was found,
 *         or -1 if no region was found.
 */
static vaddr_t alloc_spot(vmm_aspace_t* aspace,
                          size_t size,
                          uint8_t align_pow2,
                          uint arch_mmu_flags,
                          struct list_node** before) {
    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(size > 0 && IS_PAGE_ALIGNED(size));

    LTRACEF("aspace %p size 0x%zx align %hhu\n", aspace, size, align_pow2);

    if (align_pow2 < PAGE_SIZE_SHIFT)
        align_pow2 = PAGE_SIZE_SHIFT;
    vaddr_t align = 1UL << align_pow2;

    vaddr_t spot;
    vmm_region_t* left = NULL;
    vmm_region_t* right;

    /* Figure out how many options we have to size randomness appropriately */
    size_t choices = 0;
    list_for_every_entry(&aspace->region_list, right, vmm_region_t, node) {
        choices += scan_gap(aspace, left, right, align, size, arch_mmu_flags);
        left = right;
    }
    right = NULL;
    choices += scan_gap(aspace, left, right, align, size, arch_mmu_flags);
    if (!choices) {
        /* No available choices, bail */
        return (vaddr_t)-1;
    }

    /* Grab the index through all choices */
#ifdef ASLR
    /*
     * TODO this is biased for non power-of-two choices
     * Fix delayed until we get a real RNG because it may include correct
     * upper-bounding in its API
     */
    size_t index = ((size_t)rand()) % choices;
#else
    size_t index = 0;
#endif
    left = NULL;
    list_for_every_entry(&aspace->region_list, right, vmm_region_t, node) {
        size_t local_spots =
                scan_gap(aspace, left, right, align, size, arch_mmu_flags);
        if (local_spots > index) {
            spot = spot_in_gap(aspace, left, right, align, size, arch_mmu_flags,
                               index);
            goto done;
        } else {
            index -= local_spots;
        }
        left = right;
    }
    right = NULL;
    spot = spot_in_gap(aspace, left, right, align, size, arch_mmu_flags, index);

done:
    if (before)
        *before = left ? &left->node : &aspace->region_list;
    return spot;
}

bool vmm_find_spot(vmm_aspace_t* aspace, size_t size, vaddr_t* out) {
    mutex_acquire(&vmm_lock);
    *out = alloc_spot(aspace, size, PAGE_SIZE_SHIFT, 0, NULL);
    mutex_release(&vmm_lock);
    return *out != (vaddr_t)(-1);
}

/* allocate a region structure and stick it in the address space */
static vmm_region_t* alloc_region(vmm_aspace_t* aspace,
                                  const char* name,
                                  size_t size,
                                  vaddr_t vaddr,
                                  uint8_t align_pow2,
                                  uint vmm_flags,
                                  uint region_flags,
                                  uint arch_mmu_flags) {
    /* make a region struct for it and stick it in the list */
    vmm_region_t* r = alloc_region_struct(name, vaddr, size, region_flags,
                                          arch_mmu_flags);
    if (!r)
        return NULL;

    /* if they ask us for a specific spot, put it there */
    if (vmm_flags & VMM_FLAG_VALLOC_SPECIFIC) {
        /* stick it in the list, checking to see if it fits */
        if (add_region_to_aspace(aspace, r) < 0) {
            /* didn't fit */
            free(r);
            return NULL;
        }
    } else {
        /* allocate a virtual slot for it */
        struct list_node* before = NULL;

        vaddr = alloc_spot(aspace, size, align_pow2, arch_mmu_flags, &before);
        LTRACEF("alloc_spot returns 0x%lx, before %p\n", vaddr, before);

        if (vaddr == (vaddr_t)-1) {
            LTRACEF("failed to find spot\n");
            free(r);
            return NULL;
        }

        DEBUG_ASSERT(before != NULL);

        r->base = (vaddr_t)vaddr;

        /* add it to the region list */
        list_add_after(before, &r->node);
    }

    return r;
}

status_t vmm_reserve_space(vmm_aspace_t* aspace,
                           const char* name,
                           size_t size,
                           vaddr_t vaddr) {
    LTRACEF("aspace %p name '%s' size 0x%zx vaddr 0x%lx\n", aspace, name, size,
            vaddr);

    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(IS_PAGE_ALIGNED(vaddr));
    DEBUG_ASSERT(IS_PAGE_ALIGNED(size));

    if (!name)
        name = "";

    if (!aspace)
        return ERR_INVALID_ARGS;
    if (size == 0)
        return NO_ERROR;
    if (!IS_PAGE_ALIGNED(vaddr) || !IS_PAGE_ALIGNED(size))
        return ERR_INVALID_ARGS;

    if (!is_inside_aspace(aspace, vaddr))
        return ERR_OUT_OF_RANGE;

    /* trim the size */
    size = trim_to_aspace(aspace, vaddr, size);

    mutex_acquire(&vmm_lock);

    /* lookup how it's already mapped */
    uint arch_mmu_flags = 0;
    arch_mmu_query(&aspace->arch_aspace, vaddr, NULL, &arch_mmu_flags);

    /* build a new region structure */
    vmm_region_t* r =
            alloc_region(aspace, name, size, vaddr, 0, VMM_FLAG_VALLOC_SPECIFIC,
                         VMM_REGION_FLAG_RESERVED, arch_mmu_flags);

    mutex_release(&vmm_lock);
    return r ? NO_ERROR : ERR_NO_MEMORY;
}

status_t vmm_alloc_physical_etc(vmm_aspace_t* aspace,
                                const char* name,
                                size_t size,
                                void** ptr,
                                uint8_t align_log2,
                                paddr_t* paddr,
                                uint paddr_count,
                                uint vmm_flags,
                                uint arch_mmu_flags) {
    status_t ret;
    uint i;
    size_t page_size;

    LTRACEF("aspace %p name '%s' size 0x%zx ptr %p paddr 0x%lx... vmm_flags 0x%x "
            "arch_mmu_flags 0x%x\n",
            aspace, name, size, ptr ? *ptr : 0, paddr[0], vmm_flags,
            arch_mmu_flags);

    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(ptr);
    for (i = 0; i < paddr_count; i++) {
        DEBUG_ASSERT(IS_PAGE_ALIGNED(paddr[i]));
    }
    DEBUG_ASSERT(IS_PAGE_ALIGNED(size));

    if (!name)
        name = "";

    if (!aspace)
        return ERR_INVALID_ARGS;
    if (size == 0)
        return NO_ERROR;
    if (!paddr_count)
        return ERR_INVALID_ARGS;
    page_size = size / paddr_count;
    if (!IS_PAGE_ALIGNED(paddr[0]) || !IS_PAGE_ALIGNED(page_size))
        return ERR_INVALID_ARGS;

    if (!ptr) {
        return ERR_INVALID_ARGS;
    }

    vaddr_t vaddr = 0;

    /* if they're asking for a specific spot, copy the address */
    if (vmm_flags & VMM_FLAG_VALLOC_SPECIFIC) {
        vaddr = (vaddr_t)*ptr;
    }

    mutex_acquire(&vmm_lock);

    /* allocate a region and put it in the aspace list */
    vmm_region_t* r =
            alloc_region(aspace, name, size, vaddr, align_log2, vmm_flags,
                         VMM_REGION_FLAG_PHYSICAL, arch_mmu_flags);
    if (!r) {
        ret = ERR_NO_MEMORY;
        goto err_alloc_region;
    }

    /* return the vaddr */
    *ptr = (void*)r->base;

    /* map all of the pages */
    for (i = 0; i < paddr_count; i++) {
        int err = arch_mmu_map(&aspace->arch_aspace, r->base + i * page_size,
                               paddr[i], page_size / PAGE_SIZE, arch_mmu_flags);
        LTRACEF("arch_mmu_map returns %d\n", err);
    }

    ret = NO_ERROR;

err_alloc_region:
    mutex_release(&vmm_lock);
    return ret;
}

status_t vmm_alloc_contiguous(vmm_aspace_t* aspace,
                              const char* name,
                              size_t size,
                              void** ptr,
                              uint8_t align_pow2,
                              uint vmm_flags,
                              uint arch_mmu_flags) {
    status_t err = NO_ERROR;

    LTRACEF("aspace %p name '%s' size 0x%zx ptr %p align %hhu vmm_flags 0x%x "
            "arch_mmu_flags 0x%x\n",
            aspace, name, size, ptr ? *ptr : 0, align_pow2, vmm_flags,
            arch_mmu_flags);

    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(ptr);

    size = round_up(size, PAGE_SIZE);
    if (size == 0)
        return ERR_INVALID_ARGS;

    if (!ptr) {
        return ERR_INVALID_ARGS;
    }

    if (!name)
        name = "";

    vaddr_t vaddr = 0;

    /* if they're asking for a specific spot, copy the address */
    if (vmm_flags & VMM_FLAG_VALLOC_SPECIFIC) {
        vaddr = (vaddr_t)*ptr;
    }

    /* allocate physical memory up front, in case it cant be satisfied */
    struct list_node page_list;
    list_initialize(&page_list);

    paddr_t pa = 0;
    /* allocate a run of physical pages */
    size_t count =
            pmm_alloc_contiguous(size / PAGE_SIZE, align_pow2, &pa, &page_list);
    if (count < size / PAGE_SIZE) {
        /* check that the pmm didn't allocate a partial run */
        DEBUG_ASSERT(count == 0);
        err = ERR_NO_MEMORY;
        goto err;
    }

    mutex_acquire(&vmm_lock);

    /* allocate a region and put it in the aspace list */
    vmm_region_t* r =
            alloc_region(aspace, name, size, vaddr, align_pow2, vmm_flags,
                         VMM_REGION_FLAG_PHYSICAL, arch_mmu_flags);
    if (!r) {
        err = ERR_NO_MEMORY;
        goto err1;
    }

    /* return the vaddr */
    *ptr = (void*)r->base;

    /* map all of the pages */
    arch_mmu_map(&aspace->arch_aspace, r->base, pa, size / PAGE_SIZE,
                 arch_mmu_flags);
    // XXX deal with error mapping here

    vm_page_t* p;
    while ((p = list_remove_head_type(&page_list, vm_page_t, node))) {
        list_add_tail(&r->page_list, &p->node);
    }

    mutex_release(&vmm_lock);
    return NO_ERROR;

err1:
    mutex_release(&vmm_lock);
    pmm_free(&page_list);
err:
    return err;
}

status_t vmm_alloc(vmm_aspace_t* aspace,
                   const char* name,
                   size_t size,
                   void** ptr,
                   uint8_t align_pow2,
                   uint vmm_flags,
                   uint arch_mmu_flags) {
    status_t err = NO_ERROR;

    LTRACEF("aspace %p name '%s' size 0x%zx ptr %p align %hhu vmm_flags 0x%x "
            "arch_mmu_flags 0x%x\n",
            aspace, name, size, ptr ? *ptr : 0, align_pow2, vmm_flags,
            arch_mmu_flags);

    DEBUG_ASSERT(aspace);
    DEBUG_ASSERT(ptr);

    size = round_up(size, PAGE_SIZE);
    if (size == 0)
        return ERR_INVALID_ARGS;

    if (!ptr) {
        return ERR_INVALID_ARGS;
    }

    if (!name)
        name = "";

    vaddr_t vaddr = 0;

    /* if they're asking for a specific spot, copy the address */
    if (vmm_flags & VMM_FLAG_VALLOC_SPECIFIC) {
        vaddr = (vaddr_t)*ptr;
    }

    /* allocate physical memory up front, in case it cant be satisfied */

    /* allocate a random pile of pages */
    struct list_node page_list;
    list_initialize(&page_list);

    size_t count = pmm_alloc_pages(size / PAGE_SIZE, &page_list);
    DEBUG_ASSERT(count <= size);
    if (count < size / PAGE_SIZE) {
        LTRACEF("failed to allocate enough pages (asked for %zu, got %zu)\n",
                size / PAGE_SIZE, count);
        pmm_free(&page_list);
        err = ERR_NO_MEMORY;
        goto err;
    }

    mutex_acquire(&vmm_lock);

    /* allocate a region and put it in the aspace list */
    vmm_region_t* r =
            alloc_region(aspace, name, size, vaddr, align_pow2, vmm_flags,
                         VMM_REGION_FLAG_PHYSICAL, arch_mmu_flags);
    if (!r) {
        err = ERR_NO_MEMORY;
        goto err1;
    }

    /* return the vaddr */
    *ptr = (void*)r->base;

    /* map all of the pages */
    /* XXX use smarter algorithm that tries to build runs */
    vm_page_t* p;
    vaddr_t va = r->base;
    DEBUG_ASSERT(IS_PAGE_ALIGNED(va));
    while ((p = list_remove_head_type(&page_list, vm_page_t, node))) {
        DEBUG_ASSERT(va <= r->base + (r->size - 1));

        paddr_t pa = vm_page_to_paddr(p);
        DEBUG_ASSERT(IS_PAGE_ALIGNED(pa));

        arch_mmu_map(&aspace->arch_aspace, va, pa, 1, arch_mmu_flags);
        // XXX deal with error mapping here

        list_add_tail(&r->page_list, &p->node);

        if (__builtin_add_overflow(va, PAGE_SIZE, &va)) {
            ASSERT(list_is_empty(&page_list));
        }
    }

    mutex_release(&vmm_lock);
    return NO_ERROR;

err1:
    mutex_release(&vmm_lock);
    pmm_free(&page_list);
err:
    return err;
}

vmm_region_t* vmm_find_region(const vmm_aspace_t* aspace,
                              vaddr_t vaddr) {
    vmm_region_t* r;

    DEBUG_ASSERT(aspace);

    if (!aspace)
        return NULL;

    /* search the region list */
    list_for_every_entry(&aspace->region_list, r, vmm_region_t, node) {
        if (is_inside_region(r, vaddr))
            return r;
    }

    return NULL;
}

static bool vmm_region_is_match(vmm_region_t* r,
                                vaddr_t va,
                                size_t size,
                                uint32_t flags) {
    if (!r) {
        return false;
    }
    if (flags & VMM_FREE_REGION_FLAG_EXPAND) {
        return is_range_inside_region(r, va, size);
    } else {
        return r->base == va && r->size == size;
    }
}

status_t vmm_free_region_etc(vmm_aspace_t* aspace,
                             vaddr_t vaddr,
                             size_t size,
                             uint32_t flags) {
    DEBUG_ASSERT(aspace);

    mutex_acquire(&vmm_lock);

    vmm_region_t* r = vmm_find_region(aspace, vaddr);
    if (!vmm_region_is_match(r, vaddr, size, flags)) {
        mutex_release(&vmm_lock);
        return ERR_NOT_FOUND;
    }

    /* remove it from aspace */
    list_delete(&r->node);

    /* unmap it */
    arch_mmu_unmap(&aspace->arch_aspace, r->base, r->size / PAGE_SIZE);

    mutex_release(&vmm_lock);

    /* return physical pages if any */
    pmm_free(&r->page_list);

    /* free it */
    free(r);

    return NO_ERROR;
}

status_t vmm_free_region(vmm_aspace_t* aspace, vaddr_t vaddr) {
    return vmm_free_region_etc(aspace, vaddr, 1, VMM_FREE_REGION_FLAG_EXPAND);
}

status_t vmm_create_aspace(vmm_aspace_t** _aspace,
                           const char* name,
                           uint flags) {
    status_t err;

    DEBUG_ASSERT(_aspace);

    vmm_aspace_t* aspace = calloc(1, sizeof(vmm_aspace_t));
    if (!aspace)
        return ERR_NO_MEMORY;

    if (name)
        strlcpy(aspace->name, name, sizeof(aspace->name));
    else
        strlcpy(aspace->name, "unnamed", sizeof(aspace->name));

    aspace->flags = flags;

    if (aspace->flags & VMM_ASPACE_FLAG_KERNEL) {
        aspace->base = KERNEL_ASPACE_BASE;
        aspace->size = KERNEL_ASPACE_SIZE;
    } else {
        aspace->base = USER_ASPACE_BASE;
        aspace->size = USER_ASPACE_SIZE;
    }

    /* initialize the arch specific component to our address space */
    err = arch_mmu_init_aspace(&aspace->arch_aspace, aspace->base, aspace->size,
                               (aspace->flags & VMM_ASPACE_FLAG_KERNEL)
                                       ? ARCH_ASPACE_FLAG_KERNEL
                                       : 0);
    if (err < 0) {
        free(aspace);
        return err;
    }

    list_clear_node(&aspace->node);
    list_initialize(&aspace->region_list);

    mutex_acquire(&vmm_lock);
    list_add_head(&aspace_list, &aspace->node);
    mutex_release(&vmm_lock);

    *_aspace = aspace;

    return NO_ERROR;
}

status_t vmm_free_aspace(vmm_aspace_t* aspace) {
    DEBUG_ASSERT(aspace);

    /* pop it out of the global aspace list */
    mutex_acquire(&vmm_lock);
    if (!list_in_list(&aspace->node)) {
        mutex_release(&vmm_lock);
        return ERR_INVALID_ARGS;
    }
    list_delete(&aspace->node);

    /* free all of the regions */
    struct list_node region_list = LIST_INITIAL_VALUE(region_list);

    vmm_region_t* r;
    while ((r = list_remove_head_type(&aspace->region_list, vmm_region_t,
                                      node))) {
        /* add it to our tempoary list */
        list_add_tail(&region_list, &r->node);

        /* unmap it */
        arch_mmu_unmap(&aspace->arch_aspace, r->base, r->size / PAGE_SIZE);
    }
    mutex_release(&vmm_lock);

    /* without the vmm lock held, free all of the pmm pages and the structure */
    while ((r = list_remove_head_type(&region_list, vmm_region_t, node))) {
        /* return physical pages if any */
        pmm_free(&r->page_list);

        /* free it */
        free(r);
    }

    /* make sure the current thread does not map the aspace */
    thread_t* current_thread = get_current_thread();
    if (current_thread->aspace == aspace) {
        THREAD_LOCK(state);
        current_thread->aspace = NULL;
        vmm_context_switch(aspace, NULL);
        THREAD_UNLOCK(state);
    }

    /* destroy the arch portion of the aspace */
    arch_mmu_destroy_aspace(&aspace->arch_aspace);

    /* free the aspace */
    free(aspace);

    return NO_ERROR;
}

void vmm_context_switch(vmm_aspace_t* oldspace, vmm_aspace_t* newaspace) {
    DEBUG_ASSERT(thread_lock_held());

    arch_mmu_context_switch(newaspace ? &newaspace->arch_aspace : NULL);
}

void vmm_set_active_aspace(vmm_aspace_t* aspace) {
    LTRACEF("aspace %p\n", aspace);

    thread_t* t = get_current_thread();
    DEBUG_ASSERT(t);

    if (aspace == t->aspace)
        return;

    /* grab the thread lock and switch to the new address space */
    THREAD_LOCK(state);
    vmm_aspace_t* old = t->aspace;
    t->aspace = aspace;
    vmm_context_switch(old, t->aspace);
    THREAD_UNLOCK(state);
}

static void dump_region(const vmm_region_t* r) {
    DEBUG_ASSERT(r);

    printf("\tregion %p: name '%s' range 0x%lx - 0x%lx size 0x%zx flags 0x%x "
           "mmu_flags 0x%x\n",
           r, r->name, r->base, r->base + (r->size - 1), r->size, r->flags,
           r->arch_mmu_flags);
}

static void dump_aspace(const vmm_aspace_t* a) {
    DEBUG_ASSERT(a);

    printf("aspace %p: name '%s' range 0x%lx - 0x%lx size 0x%zx flags 0x%x\n",
           a, a->name, a->base, a->base + (a->size - 1), a->size, a->flags);

    printf("regions:\n");
    vmm_region_t* r;
    list_for_every_entry(&a->region_list, r, vmm_region_t, node) {
        dump_region(r);
    }
}

static int cmd_vmm(int argc, const cmd_args* argv) {
    if (argc < 2) {
    notenoughargs:
        printf("not enough arguments\n");
    usage:
        printf("usage:\n");
        printf("%s aspaces\n", argv[0].str);
        printf("%s alloc <size> <align_pow2>\n", argv[0].str);
        printf("%s alloc_physical <paddr> <size> <align_pow2>\n", argv[0].str);
        printf("%s alloc_contig <size> <align_pow2>\n", argv[0].str);
        printf("%s free_region <address>\n", argv[0].str);
        printf("%s create_aspace\n", argv[0].str);
        printf("%s create_test_aspace\n", argv[0].str);
        printf("%s free_aspace <address>\n", argv[0].str);
        printf("%s set_test_aspace <address>\n", argv[0].str);
        return ERR_GENERIC;
    }

    static vmm_aspace_t* test_aspace;
    if (!test_aspace)
        test_aspace = vmm_get_kernel_aspace();

    if (!strcmp(argv[1].str, "aspaces")) {
        vmm_aspace_t* a;
        list_for_every_entry(&aspace_list, a, vmm_aspace_t, node) {
            dump_aspace(a);
        }
    } else if (!strcmp(argv[1].str, "alloc")) {
        if (argc < 4)
            goto notenoughargs;

        void* ptr = (void*)0x99;
        status_t err = vmm_alloc(test_aspace, "alloc test", argv[2].u, &ptr,
                                 argv[3].u, 0, 0);
        printf("vmm_alloc returns %d, ptr %p\n", err, ptr);
    } else if (!strcmp(argv[1].str, "alloc_physical")) {
        if (argc < 4)
            goto notenoughargs;

        void* ptr = (void*)0x99;
        status_t err = vmm_alloc_physical(test_aspace, "physical test",
                                          argv[3].u, &ptr, argv[4].u, argv[2].u,
                                          0, ARCH_MMU_FLAG_UNCACHED_DEVICE);
        printf("vmm_alloc_physical returns %d, ptr %p\n", err, ptr);
    } else if (!strcmp(argv[1].str, "alloc_contig")) {
        if (argc < 4)
            goto notenoughargs;

        void* ptr = (void*)0x99;
        status_t err = vmm_alloc_contiguous(test_aspace, "contig test",
                                            argv[2].u, &ptr, argv[3].u, 0, 0);
        printf("vmm_alloc_contig returns %d, ptr %p\n", err, ptr);
    } else if (!strcmp(argv[1].str, "free_region")) {
        if (argc < 2)
            goto notenoughargs;

        status_t err = vmm_free_region(test_aspace, (vaddr_t)argv[2].u);
        printf("vmm_free_region returns %d\n", err);
    } else if (!strcmp(argv[1].str, "create_aspace")) {
        vmm_aspace_t* aspace;
        status_t err = vmm_create_aspace(&aspace, "test", 0);
        printf("vmm_create_aspace returns %d, aspace %p\n", err, aspace);
    } else if (!strcmp(argv[1].str, "create_test_aspace")) {
        vmm_aspace_t* aspace;
        status_t err = vmm_create_aspace(&aspace, "test", 0);
        printf("vmm_create_aspace returns %d, aspace %p\n", err, aspace);
        if (err < 0)
            return err;

        test_aspace = aspace;
        get_current_thread()->aspace = aspace;
        thread_sleep(1);  // XXX hack to force it to reschedule and thus load
                          // the aspace
    } else if (!strcmp(argv[1].str, "free_aspace")) {
        if (argc < 2)
            goto notenoughargs;

        vmm_aspace_t* aspace = (void*)argv[2].u;
        if (test_aspace == aspace)
            test_aspace = NULL;

        if (get_current_thread()->aspace == aspace) {
            get_current_thread()->aspace = NULL;
            thread_sleep(1);  // hack
        }

        status_t err = vmm_free_aspace(aspace);
        printf("vmm_free_aspace returns %d\n", err);
    } else if (!strcmp(argv[1].str, "set_test_aspace")) {
        if (argc < 2)
            goto notenoughargs;

        test_aspace = (void*)argv[2].u;
        get_current_thread()->aspace = test_aspace;
        thread_sleep(1);  // XXX hack to force it to reschedule and thus load
                          // the aspace
    } else {
        printf("unknown command\n");
        goto usage;
    }

    return NO_ERROR;
}

STATIC_COMMAND_START
#if LK_DEBUGLEVEL > 0
STATIC_COMMAND("vmm", "virtual memory manager", &cmd_vmm)
#endif
STATIC_COMMAND_END(vmm);
