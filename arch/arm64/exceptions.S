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
#include <asm.h>

.section .text.boot.vectab
.align 12

.macro push ra, rb
stp \ra, \rb, [sp,#-16]!
.endm

.macro pop ra, rb
ldp \ra, \rb, [sp], #16
.endm

#define lr x30
#define regsave_long_offset 0xf0

.macro regsave_long
sub  sp, sp, #32
push x28, x29
push x26, x27
push x24, x25
push x22, x23
push x20, x21
push x18, x19
push x16, x17
push x14, x15
push x12, x13
push x10, x11
push x8, x9
push x6, x7
push x4, x5
push x2, x3
push x0, x1
add  x0, sp, #regsave_long_offset
mrs  x1, elr_el1
mrs  x2, spsr_el1
stp  lr, x0, [sp, #regsave_long_offset]
stp  x1, x2, [sp, #regsave_long_offset + 16]
.endm

.macro regrestore_long
ldr  lr, [sp, #regsave_long_offset]
ldp  x1, x2, [sp, #regsave_long_offset + 16]
msr  elr_el1, x1
msr  spsr_el1, x2
pop x0, x1
pop x2, x3
pop x4, x5
pop x6, x7
pop x8, x9
pop x10, x11
pop x12, x13
pop x14, x15
pop x16, x17
pop x18, x19
pop x20, x21
pop x22, x23
pop x24, x25
pop x26, x27
pop x28, x29
add sp, sp, #32
.endm

.macro invalid_exception, which
    regsave_long
    mov x1, #\which
    mov x0, sp
    bl  arm64_invalid_exception
    b   .
.endm

FUNCTION(arm64_exception_base)

/* exceptions from current EL, using SP0 */
LOCAL_FUNCTION(arm64_sync_exc_current_el_SP0)
    invalid_exception 0

.org 0x080
LOCAL_FUNCTION(arm64_irq_current_el_SP0)
    invalid_exception 1

.org 0x100
LOCAL_FUNCTION(arm64_fiq_current_el_SP0)
    invalid_exception 2

.org 0x180
LOCAL_FUNCTION(arm64_err_exc_current_el_SP0)
    invalid_exception 3

/* exceptions from current EL, using SPx */
.org 0x200
LOCAL_FUNCTION(arm64_sync_exc_current_el_SPx)
    regsave_long
    mov x0, sp
    bl  arm64_sync_exception
    b  arm64_exc_shared_restore

.org 0x280
LOCAL_FUNCTION(arm64_irq_current_el_SPx)
    regsave_long
    mov x0, sp
    bl  platform_irq
    b  arm64_exc_shared_restore

.org 0x300
LOCAL_FUNCTION(arm64_fiq_current_el_SPx)
    regsave_long
    mov x0, sp
    bl  platform_fiq
    b  arm64_exc_shared_restore

.org 0x380
LOCAL_FUNCTION(arm64_err_exc_current_el_SPx)
    invalid_exception 0x13

/* exceptions from lower EL, running arm64 */
.org 0x400
LOCAL_FUNCTION(arm64_sync_exc_lower_el_64)
    invalid_exception 0x20

.org 0x480
LOCAL_FUNCTION(arm64_irq_lower_el_64)
    invalid_exception 0x21

.org 0x500
LOCAL_FUNCTION(arm64_fiq_lower_el_64)
    invalid_exception 0x22

.org 0x580
LOCAL_FUNCTION(arm64_err_exc_lower_el_64)
    invalid_exception 0x23

/* exceptions from lower EL, running arm32 */
.org 0x600
LOCAL_FUNCTION(arm64_sync_exc_lower_el_32)
    invalid_exception 0x30

.org 0x680
LOCAL_FUNCTION(arm64_irq_lower_el_32)
    invalid_exception 0x31

.org 0x700
LOCAL_FUNCTION(arm64_fiq_lower_el_32)
    invalid_exception 0x32

.org 0x780
LOCAL_FUNCTION(arm64_err_exc_lower_el_32)
    invalid_exception 0x33

LOCAL_FUNCTION(arm64_exc_shared_restore)
    regrestore_long
    eret
