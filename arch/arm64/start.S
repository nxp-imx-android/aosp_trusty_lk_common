#include <asm.h>
#include <arch/arm64/mmu.h>
#include <arch/asm_macros.h>
#include <kernel/vm.h>

/*
 * Register use:
 *  x0-x3   Arguments
 *  x9-x15  Scratch
 *  x18     Shadow stack pointer (if enabled)
 *  x19-x28 Globals
 */
tmp                     .req x9
tmp2                    .req x10
wtmp2                   .req w10
index                   .req x11
index_shift             .req x12
page_table              .req x13
new_page_table          .req x14
phys_offset             .req x15

ssp                     .req x18
cpuid                   .req x19
page_table0             .req x20
page_table1             .req x21
mmu_initial_mapping     .req x22
vaddr                   .req x23
paddr                   .req x24
mapping_size            .req x25
size                    .req x26
attr                    .req x27

.section .text.boot
FUNCTION(_start)
.globl arm_reset
arm_reset:
    bl      arm64_elX_to_el1

#if WITH_KERNEL_VM
    /* enable caches so atomics and spinlocks work */
    mrs     tmp, sctlr_el1
    orr     tmp, tmp, #(1<<12) /* Enable icache */
    orr     tmp, tmp, #(1<<2)  /* Enable dcache/ucache */
    orr     tmp, tmp, #(1<<3)  /* Enable Stack Alignment Check EL1 */
    orr     tmp, tmp, #(1<<4)  /* Enable Stack Alignment Check EL0 */
    bic     tmp, tmp, #(1<<1)  /* Disable Alignment Checking for EL1 EL0 */
    msr     sctlr_el1, tmp

    /* set up the mmu according to mmu_initial_mappings */

    /* load the base of the translation table and clear the table */
    adrl    page_table1, arm64_kernel_translation_table

    /* Prepare tt_trampoline page table */
    /* Calculate pagetable physical addresses */
    adrl    page_table0, tt_trampoline

#if WITH_SMP
    /*
     * Stash x0 as it will be clobbered
     * We place it in size as x0 contains the size passed to the entry point.
     */
    mov     size, x0
    /* Get the CPU number */
    bl      arm64_curr_cpu_num
    mov     cpuid, x0
    /* Restore registers */
    mov     x0, size
    cbnz    cpuid, .Ltt_trampoline_check_secondary
#endif

    /* Zero the top level kernel page table */
    mov     tmp, #0

    /* walk through all the entries in the translation table, setting them up */
.Lclear_top_page_table_loop:
    str     xzr, [page_table1, tmp, lsl #3]
    add     tmp, tmp, #1
    cmp     tmp, #MMU_KERNEL_PAGE_TABLE_ENTRIES_TOP
    bne     .Lclear_top_page_table_loop

    /* Prepare tt_trampoline page table */

    /* Zero tt_trampoline translation tables */
    mov     tmp, #0
.Lclear_tt_trampoline:
    str     xzr, [page_table0, tmp, lsl#3]
    add     tmp, tmp, #1
    cmp     tmp, #MMU_PAGE_TABLE_ENTRIES_IDENT
    blt     .Lclear_tt_trampoline

    /* Setup mapping at phys -> phys */
    /*
     * Map from the start of the kernel to the end of RAM
     * so we have enough pages for boot_alloc memory.
     */
    adr     index, _start
    lsr     tmp, index, #MMU_IDENT_TOP_SHIFT    /* tmp = paddr index */

    /* Check that the start index falls inside the table */
    cmp     tmp, #MMU_PAGE_TABLE_ENTRIES_IDENT
    b.hs    platform_early_halt

    /*
     * The physical address of last byte of the kernel image is (_start + x0 - 1),
     * and we round that down to a multiple of 1<<MMU_IDENT_TOP_SHIFT
     * to get the inclusive upper bound of the tt_trampoline range.
     */
    add     index, index, x0
    sub     index, index, #1
    lsr     index, index, #MMU_IDENT_TOP_SHIFT

    /* Clamp the end index to the last possible entry */
    cmp     index, #MMU_PAGE_TABLE_ENTRIES_IDENT
    b.lo    .Lset_tt_trampoline_loop
    mov     index, #(MMU_PAGE_TABLE_ENTRIES_IDENT - 1)

.Lset_tt_trampoline_loop:
    cmp     tmp, index
    b.hi   .Lset_tt_trampoline_done

    ldr     tmp2, =MMU_PTE_IDENT_FLAGS
    add     tmp2, tmp2, tmp, lsl #MMU_IDENT_TOP_SHIFT  /* tmp2 = pt entry */
    str     tmp2, [page_table0, tmp, lsl #3]     /* tt_trampoline[paddr index] = pt entry */
    add     tmp, tmp, #1
    b       .Lset_tt_trampoline_loop

.Lset_tt_trampoline_done:

#if WITH_SMP
    /* Release the first lock on the secondary CPUs */
    adrl    tmp, tt_trampoline_not_ready
    str     wzr, [tmp]
    b       .Ltt_trampoline_ready

.Ltt_trampoline_check_secondary:
    adrl    tmp, tt_trampoline_not_ready
.Ltt_trampoline_not_ready:
    ldr     wtmp2, [tmp]
    cbnz    wtmp2, .Ltt_trampoline_not_ready
.Ltt_trampoline_ready:
#endif

    /* set up the mmu */

    /* Invalidate TLB */
    tlbi    vmalle1is
    isb
    dsb     sy

    /* Initialize Memory Attribute Indirection Register */
    ldr     tmp, =MMU_MAIR_VAL
    msr     mair_el1, tmp

    /* Initialize TCR_EL1 */
    /* set cacheable attributes on translation walk */
    /* (SMP extensions) non-shareable, inner write-back write-allocate */
    ldr     tmp, =MMU_TCR_FLAGS_IDENT
    msr     tcr_el1, tmp

    isb

    /* Write ttbr with phys addr of the translation table */
    msr     ttbr0_el1, page_table0
    msr     ttbr1_el1, page_table1
    isb

    /* Read SCTLR */
    mrs     tmp, sctlr_el1

    /* Turn on the MMU */
    orr     tmp, tmp, #0x1

    /* Write back SCTLR */
    msr     sctlr_el1, tmp
    isb

#if WITH_SMP
    cbnz    cpuid, .Lpage_tables_check_secondary
#endif
#endif /* WITH_KERNEL_VM */

    /* clear bss */
.L__do_bss:
    /* clear out the bss excluding the stack and kernel translation table  */
    /* NOTE: relies on __post_prebss_bss_start and __bss_end being 8 byte aligned */
    adrl    tmp, __post_prebss_bss_start
    adrl    tmp2, __bss_end
    sub     tmp2, tmp2, tmp
    cbz     tmp2, .L__bss_loop_done
.L__bss_loop:
    sub     tmp2, tmp2, #8
    str     xzr, [tmp], #8
    cbnz    tmp2, .L__bss_loop
.L__bss_loop_done:

#if WITH_KERNEL_VM
    /* Set up the stack */
    adrl    tmp, __stack_end
    mov     sp, tmp

#if KERNEL_SCS_ENABLED
    adrl    ssp, __shadow_stack
#endif

    /* Save the arguments */
    push    x2, x3
    push    x0, x1

    bl      arm64_early_mmu_init

    /* load the address of the mmu_initial_mappings table and start processing */
    adrl    mmu_initial_mapping, mmu_initial_mappings

.Linitial_mapping_loop:
/* Read entry of mmu_initial_mappings (likely defined in platform.c) */
    ldp     paddr, vaddr, [mmu_initial_mapping, #__MMU_INITIAL_MAPPING_PHYS_OFFSET]
    ldp     size, tmp, [mmu_initial_mapping, #__MMU_INITIAL_MAPPING_SIZE_OFFSET]

    tbzmask tmp, MMU_INITIAL_MAPPING_FLAG_DYNAMIC, .Lnot_dynamic
    adr     paddr, _start
    mov     size, x0
    str     paddr, [mmu_initial_mapping, #__MMU_INITIAL_MAPPING_PHYS_OFFSET]
    str     size, [mmu_initial_mapping, #__MMU_INITIAL_MAPPING_SIZE_OFFSET]

.Lnot_dynamic:
    /* if size == 0, end of list, done with initial mapping */
    cbz     size, .Linitial_mapping_done
    mov     mapping_size, size

    /* set up the flags */
    tbzmask tmp, MMU_INITIAL_MAPPING_FLAG_UNCACHED, .Lnot_uncached
    ldr     attr, =MMU_INITIAL_MAP_STRONGLY_ORDERED
    b       .Lmem_type_done

.Lnot_uncached:
    /* is this memory mapped to device/peripherals? */
    tbzmask tmp, MMU_INITIAL_MAPPING_FLAG_DEVICE, .Lnot_device
    ldr     attr, =MMU_INITIAL_MAP_DEVICE
    b       .Lmem_type_done
.Lnot_device:

/* Determine the segment in which the memory resides and set appropriate
 *  attributes.  In order to handle offset kernels, the following rules are
 *  implemented below:
 *      KERNEL_BASE    to __code_start             -read/write (see note below)
 *      __code_start   to __rodata_start (.text)   -read only
 *      __rodata_start to __data_start   (.rodata) -read only, execute never
 *      __data_start   to .....          (.data)   -read/write
 *
 *  The space below __code_start is presently left as read/write (same as .data)
 *   mainly as a workaround for the raspberry pi boot process.  Boot vectors for
 *   secondary CPUs are in this area and need to be updated by cpu0 once the system
 *   is ready to boot the secondary processors.
 *   TODO: handle this via mmu_initial_mapping entries, which may need to be
 *         extended with additional flag types
 */
.Lmapping_size_loop:
    ldr     attr, =MMU_PTE_KERNEL_DATA_FLAGS
    adrl    tmp, __code_start
    subs    size, tmp, paddr
    /* If page is below  the entry point (_start) mark as kernel data */
    b.hi    .Lmem_type_done

    ldr     attr, =MMU_PTE_KERNEL_RO_FLAGS
    adrl    tmp, __rodata_start
    subs    size, tmp, paddr
    b.hi    .Lmem_type_done
    orr     attr, attr, #MMU_PTE_ATTR_PXN
    adrl    tmp, __data_start
    subs    size, tmp, paddr
    b.hi    .Lmem_type_done
    ldr     attr, =MMU_PTE_KERNEL_DATA_FLAGS
    adrl    tmp, _end
    subs    size, tmp, paddr
    b.lo    . /* Error: phys(_end) < paddr */
    cmp     mapping_size, size
    b.lo    . /* Error: mapping_size < size => RAM size too small for data/bss */
    mov     size, mapping_size

.Lmem_type_done:
    subs    mapping_size, mapping_size, size
    b.lo    . /* Error: mapping_size < size (RAM size too small for code/rodata?) */

    /* Check that paddr, vaddr and size are page aligned */
    orr     tmp, vaddr, paddr
    orr     tmp, tmp, size
    tst     tmp, #(1 << MMU_KERNEL_PAGE_SIZE_SHIFT) - 1
    bne     . /* Error: not page aligned */

    /* Clear top bits of virtual address (should be all set) */
    eor     vaddr, vaddr, #(~0 << MMU_KERNEL_SIZE_SHIFT)

    /* Check that top bits were all set */
    tst     vaddr, #(~0 << MMU_KERNEL_SIZE_SHIFT)
    bne     . /* Error: vaddr out of range */

.Lmap_range_top_loop:
    /* Select top level page table */
    mov     page_table, page_table1
    mov     index_shift, #MMU_KERNEL_TOP_SHIFT

    lsr     index, vaddr, index_shift


/* determine the type of page table entry to use given alignment and size
 *  of the chunk of memory we are mapping
 */
.Lmap_range_one_table_loop:
    /* Check if current level allow block descriptors */
    cmp     index_shift, #MMU_PTE_DESCRIPTOR_BLOCK_MAX_SHIFT
    b.hi    .Lmap_range_need_page_table

    /* Check if paddr and vaddr alignment allows a block descriptor */
    orr     tmp2, vaddr, paddr
    lsr     tmp, tmp2, index_shift
    lsl     tmp, tmp, index_shift
    cmp     tmp, tmp2
    b.ne    .Lmap_range_need_page_table

    /* Check if size is large enough for a block mapping */
    lsr     tmp, size, index_shift
    cbz     tmp, .Lmap_range_need_page_table

    /* Select descriptor type, page for level 3, block for level 0-2 */
    orr     tmp, attr, #MMU_PTE_L3_DESCRIPTOR_PAGE
    cmp     index_shift, MMU_KERNEL_PAGE_SIZE_SHIFT
    beq     .Lmap_range_l3
    orr     tmp, attr, #MMU_PTE_L012_DESCRIPTOR_BLOCK
.Lmap_range_l3:

    /* Write page table entry */
    orr     tmp, tmp, paddr
    str     tmp, [page_table, index, lsl #3]

    /* Move to next page table entry */
    mov     tmp, #1
    lsl     tmp, tmp, index_shift
    add     vaddr, vaddr, tmp
    add     paddr, paddr, tmp
    subs    size, size, tmp
    /* TODO: add local loop if next entry is in the same page table */
    b.ne    .Lmap_range_top_loop /* size != 0 */

    /* Restore top bits of virtual address (should be all set) */
    eor     vaddr, vaddr, #(~0 << MMU_KERNEL_SIZE_SHIFT)
    /* Move to next subtype of ram mmu_initial_mappings entry */
    cbnz     mapping_size, .Lmapping_size_loop

    /* Move to next mmu_initial_mappings entry */
    add     mmu_initial_mapping, mmu_initial_mapping, __MMU_INITIAL_MAPPING_SIZE
    b       .Linitial_mapping_loop

.Lmap_range_need_page_table:
    /* Check if page table entry is unused */
    ldr     new_page_table, [page_table, index, lsl #3]
    cbnz    new_page_table, .Lmap_range_has_page_table

    /* Calculate phys offset (needed for memory allocation) */
.Lphys_offset:
    ldr     phys_offset, =(KERNEL_BASE + KERNEL_LOAD_OFFSET)
    adrl    tmp, __code_start
    sub     phys_offset, phys_offset, tmp

    /* Allocate new page table */
    calloc_bootmem_aligned new_page_table, tmp, tmp2, MMU_KERNEL_PAGE_SIZE_SHIFT, phys_offset

    /* Write page table entry (with allocated page table) */
    orr     new_page_table, new_page_table, #MMU_PTE_L012_DESCRIPTOR_TABLE
    str     new_page_table, [page_table, index, lsl #3]

.Lmap_range_has_page_table:
    /* Check descriptor type */
    and     tmp, new_page_table, #MMU_PTE_DESCRIPTOR_MASK
    cmp     tmp, #MMU_PTE_L012_DESCRIPTOR_TABLE
    b.ne    . /* Error: entry already in use (as a block entry) */

    /* switch to next page table level */
    bic     page_table, new_page_table, #MMU_PTE_DESCRIPTOR_MASK
    mov     tmp, #~0
    lsl     tmp, tmp, index_shift
    bic     tmp, vaddr, tmp
    sub     index_shift, index_shift, #(MMU_KERNEL_PAGE_SIZE_SHIFT - 3)
    lsr     index, tmp, index_shift

    b       .Lmap_range_one_table_loop

.Linitial_mapping_done:

    /* Restore the arguments */
    pop     x0, x1
    pop     x2, x3

    /* Check the stack offset */
    adrl    tmp, __stack_end
    mov     tmp2, sp
    cmp     tmp, tmp2
    b.ne    platform_early_halt /* Error: invalid SP on return from C */

#if WITH_SMP
    /* Release the second lock on the secondary CPUs */
    adrl    tmp, page_tables_not_ready
    stlr    wzr, [tmp]
    b       .Lpage_tables_ready

.Lpage_tables_check_secondary:
    adrl    tmp, page_tables_not_ready
.Lpage_tables_not_ready:
    ldar    wtmp2, [tmp]
    cbnz    wtmp2, .Lpage_tables_not_ready
.Lpage_tables_ready:
#endif
    isb

    /* Jump to virtual code address */
    adrl    tmp, mmu_on_vaddr_ptr
    ldr     tmp, [tmp]
    br      tmp

.Lmmu_on_vaddr:

    /* Disable trampoline page-table in ttbr0 */
    ldr     tmp, =MMU_TCR_FLAGS_KERNEL
    msr     tcr_el1, tmp
    isb


    /* Invalidate TLB */
    tlbi    vmalle1
    isb

#if WITH_SMP
    cbnz    cpuid, .Lsecondary_boot
#endif
#endif /* WITH_KERNEL_VM */

    adrl    tmp, sp_el1_bufs
    mov     sp, tmp

    msr     spsel, #0 /* Use SP0 for kernel stacks */
    adrl    tmp, __stack_end
    mov sp, tmp

#if KERNEL_SCS_ENABLED
    adrl    ssp, __shadow_stack
#endif

    bl  lk_main
    b   .

#if WITH_SMP
/*
 *  Decodes the CPU number out of MPIDR.
 *  This can be overridden by the platform.
 *  If it is, it must:
 *  - Not assume a stack
 *  - Only clobber x0, x9, x10
 *  - Return the CPU number in x0
 *  - If the CPU number would be invalid, return SMP_MAX_CPUS
 */
WEAK_FUNCTION(arm64_curr_cpu_num)
    mrs     x0, mpidr_el1
    ubfx    x0, x0, #0, #SMP_CPU_ID_BITS
    and     tmp, x0, #0xff
    cmp     tmp, #(1 << SMP_CPU_CLUSTER_SHIFT)
    bge     .Lunsupported_cpu_num
    bic     x0, x0, #0xff
    orr     x0, tmp, x0, LSR #(8 - SMP_CPU_CLUSTER_SHIFT)
    ret

.Lunsupported_cpu_num:
    mov     x0, #SMP_MAX_CPUS
    ret

.Lsecondary_boot:
    cmp     cpuid, #SMP_MAX_CPUS
    bge     .Lunsupported_cpu_trap

    /* Set up the stack pointers */
    adrl    tmp, sp_el1_bufs
    mov     tmp2, #ARM64_EXC_SP_EL1_BUF_SIZE
    mul     tmp2, tmp2, cpuid
    add     sp, tmp, tmp2

    msr     spsel, #0 /* Use SP0 for kernel stacks */

    adrl    tmp, __stack_end
    mov     tmp2, #ARCH_DEFAULT_STACK_SIZE
    mul     tmp2, tmp2, cpuid
    sub     sp, tmp, tmp2

#if KERNEL_SCS_ENABLED
    /* Set up the shadow stack pointer */
    adrl    ssp, __shadow_stack
    mov     tmp, #ARCH_DEFAULT_SHADOW_STACK_SIZE
    mul     tmp, tmp, cpuid
    add     ssp, ssp, tmp
#endif

    mov     x0, cpuid
    bl      arm64_secondary_entry

.Lunsupported_cpu_trap:
    wfe
    b       .Lunsupported_cpu_trap
#endif

.ltorg

#if WITH_KERNEL_VM
.data
DATA(mmu_on_vaddr_ptr)
.hidden mmu_on_vaddr_ptr
    /*
     * Store a pointer to the virtual address of .Lmmu_on_vaddr inside a
     * pointer quad that KASLR can relocate. We compute the address explicitly
     * here because the linker script places the kernel at its physical
     * address, and we want the virtual address instead.
     */
    .align 3
    .quad ((.Lmmu_on_vaddr - _start) + KERNEL_BASE + KERNEL_LOAD_OFFSET)
#endif

#if WITH_SMP
.data
DATA(tt_trampoline_not_ready)
    /*
     * The primary processor clears this when the ttbr0 page tables
     * are ready and all processors can enable their MMUs. Before
     * passing this semaphore, all CPUs should have MMUs off, and
     * turn them on immediately after.
     */
    .long       1
DATA(page_tables_not_ready)
    /*
     * The primary processor clears this when the final (ttbr1)
     * page tables are ready.
     */
    .long       1
#endif

.section .bss.prebss.stack
    .align 4
DATA(__stack)
    .skip ARCH_DEFAULT_STACK_SIZE * SMP_MAX_CPUS
DATA(__stack_end)

#if KERNEL_SCS_ENABLED
.section .bss.prebss.shadow_stack
    /*
     * Request 2^3 = 8-byte alignment. For aarch64, the stack pointer
     * alignment must be two times the pointer size (2^4) but the same is not
     * required for the shadow stack. Protecting the shadow stack with Memory
     * Tagging Extensions may require matching MTE's 16-byte tag granularity.
     */
    .align 3
DATA(__shadow_stack)
    .skip ARCH_DEFAULT_SHADOW_STACK_SIZE * SMP_MAX_CPUS
#endif

.section .bss.prebss.sp_el1_bufs
    .align 4
DATA(sp_el1_bufs)
    .skip ARM64_EXC_SP_EL1_BUF_SIZE * SMP_MAX_CPUS

#if WITH_KERNEL_VM
.section ".bss.prebss.translation_table"
.align 3 + MMU_PAGE_TABLE_ENTRIES_IDENT_SHIFT
DATA(tt_trampoline)
    .skip 8 * MMU_PAGE_TABLE_ENTRIES_IDENT
#endif
