/*
 * Copyright (c) 2014-2016 Travis Geiselbrecht
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
#include <debug.h>
#include <stdbool.h>
#include <stdlib.h>
#include <arch.h>
#include <arch/ops.h>
#include <arch/arm64.h>
#include <arch/arm64/mmu.h>
#include <arch/mp.h>
#include <kernel/thread.h>
#include <lk/init.h>
#include <lk/main.h>
#include <platform.h>
#include <trace.h>

#define LOCAL_TRACE 0

#if WITH_SMP
/* smp boot lock */
static spin_lock_t arm_boot_cpu_lock = 1;
static volatile int secondaries_to_init = 0;
#endif

static void arm64_cpu_early_init(void)
{
    /* set the vector base */
    ARM64_WRITE_SYSREG(VBAR_EL1, (uint64_t)&arm64_exception_base);

    /* switch to EL1 */
    unsigned int current_el = ARM64_READ_SYSREG(CURRENTEL) >> 2;
    if (current_el > 1) {
        arm64_el3_to_el1();
    }

    arch_enable_fiqs();
}

void arch_early_init(void)
{
    arm64_cpu_early_init();
    platform_init_mmu_mappings();
}

void arch_init(void)
{
#if WITH_SMP
    arch_mp_init_percpu();

    LTRACEF("midr_el1 0x%llx\n", ARM64_READ_SYSREG(midr_el1));

    secondaries_to_init = SMP_MAX_CPUS - 1; /* TODO: get count from somewhere else, or add cpus as they boot */

    lk_init_secondary_cpus(secondaries_to_init);

    LTRACEF("releasing %d secondary cpus\n", secondaries_to_init);

    /* release the secondary cpus */
    spin_unlock(&arm_boot_cpu_lock);

    /* flush the release of the lock, since the secondary cpus are running without cache on */
    arch_clean_cache_range((addr_t)&arm_boot_cpu_lock, sizeof(arm_boot_cpu_lock));
#endif
}

void arch_quiesce(void)
{
}

void arch_idle(void)
{
    __asm__ volatile("wfi");
}

void arch_chain_load(void *entry, ulong arg0, ulong arg1, ulong arg2, ulong arg3)
{
    PANIC_UNIMPLEMENTED;
}

/* switch to user mode, set the user stack pointer to user_stack_top, put the svc stack pointer to the top of the kernel stack */
void arch_enter_uspace(vaddr_t entry_point, vaddr_t user_stack_top, uint32_t flags, ulong arg0)
{
    bool is_32bit_uspace = (flags & ARCH_ENTER_USPACE_FLAG_32BIT);
    user_stack_top = round_down(user_stack_top, is_32bit_uspace ? 8 : 16);

    thread_t *ct = get_current_thread();

    vaddr_t kernel_stack_top = (uintptr_t)ct->stack + ct->stack_size;
    kernel_stack_top = round_down(kernel_stack_top, 16);

    /* set up a default spsr to get into 64bit user space:
     * zeroed NZCV
     * no SS, no IL, no D
     * all interrupts enabled
     * mode 0: EL0t
     */
    uint64_t spsr = is_32bit_uspace ? 0x10 : 0;

    arch_disable_ints();

    __asm__ volatile(
        "mov    x0, %[arg0];"
        "mov    x13, %[ustack];" /* AArch32 SP_usr */
        "mov    x14, %[entry];" /* AArch32 LR_usr */
        "mov    sp, %[kstack];"
        "msr    sp_el0, %[ustack];" /* AArch64 SP_usr */
        "msr    elr_el1, %[entry];"
        "msr    spsr_el1, %[spsr];"
        "mov    x1, xzr;"
        "mov    x2, xzr;"
        "mov    x3, xzr;"
        "mov    x4, xzr;"
        "mov    x5, xzr;"
        "mov    x6, xzr;"
        "mov    x7, xzr;"
        "mov    x8, xzr;"
        "mov    x9, xzr;"
        "mov    x10, xzr;"
        "mov    x11, xzr;"
        "mov    x12, xzr;"
        "mov    x15, xzr;"
        "mov    x16, xzr;"
        "mov    x17, xzr;"
        "mov    x18, xzr;"
        "mov    x19, xzr;"
        "mov    x20, xzr;"
        "mov    x21, xzr;"
        "mov    x22, xzr;"
        "mov    x23, xzr;"
        "mov    x24, xzr;"
        "mov    x25, xzr;"
        "mov    x26, xzr;"
        "mov    x27, xzr;"
        "mov    x28, xzr;"
        "mov    x29, xzr;"
        "mov    x30, xzr;"
        "eret;"
        :
        : [arg0]"r"(arg0),
        [ustack]"r"(user_stack_top),
        [kstack]"r"(kernel_stack_top),
        [entry]"r"(entry_point),
        [spsr]"r"(spsr)
        : "x0", "x13", "x14", "memory");
    __UNREACHABLE;
}

#if WITH_SMP
void arm64_secondary_entry(ulong asm_cpu_num)
{
    uint cpu = arch_curr_cpu_num();
#ifndef WITH_BOOT_FROM_A72
    if (cpu != asm_cpu_num)
        return;
#endif

    arm64_cpu_early_init();

    spin_lock(&arm_boot_cpu_lock);
    spin_unlock(&arm_boot_cpu_lock);

    /* run early secondary cpu init routines up to the threading level */
    lk_init_level(LK_INIT_FLAG_SECONDARY_CPUS, LK_INIT_LEVEL_EARLIEST, LK_INIT_LEVEL_THREADING - 1);

    arch_mp_init_percpu();

    LTRACEF("cpu num %d\n", cpu);

    /* we're done, tell the main cpu we're up */
    atomic_add(&secondaries_to_init, -1);
    __asm__ volatile("sev");

    lk_secondary_cpu_entry();
}
#endif

void arch_set_user_tls(vaddr_t tls_ptr)
{
    /*
     * Note arm32 user space uses the ro TLS register and arm64 uses rw.
     * This matches existing ABIs.
     */
#ifdef USER_32BIT
    /* Lower bits of tpidrro_el0 aliased with arm32 tpidruro. */
    __asm__ volatile("msr tpidrro_el0, %0" :: "r" (tls_ptr));
#else
    /* Can also set from user space. Implemented here for uniformity. */
    __asm__ volatile("msr tpidr_el0, %0" :: "r" (tls_ptr));
#endif
}
