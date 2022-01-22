/*
 * Copyright (c) 2021 Google Inc. All rights reserved
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
#include <kernel/vm.h>
#include <lk/compiler.h>
#include <sys/types.h>

void arm64_early_mmu_init(ulong ram_size, uintptr_t* relr_start,
                          uintptr_t* relr_end, paddr_t kernel_paddr) {
    const uintptr_t kernel_initial_vaddr = KERNEL_BASE + KERNEL_LOAD_OFFSET;
    uintptr_t virt_offset = kernel_initial_vaddr - kernel_paddr;
    update_relocation_entries(relr_start, relr_end, virt_offset);

    /* Relocate the kernel to its physical address */
    relocate_kernel(relr_start, relr_end, kernel_initial_vaddr, kernel_paddr);

    /* Relocate the kernel to its final virtual address */
    vaddr_t kernel_final_vaddr = kernel_initial_vaddr;
    relocate_kernel(relr_start, relr_end, kernel_paddr, kernel_final_vaddr);
}
