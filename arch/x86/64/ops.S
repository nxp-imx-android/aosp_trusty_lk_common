/*
 * Copyright (c) 2009 Corey Tabaka
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

.text

/* This follows the x86-64 ABI, the parameters are stored in registers in the following order*/
/*
%rdi used to pass 1st argument
%rsi used to pass 2nd argument
%rdx used to pass 3rd argument and 2nd return register
%rcx used to pass 4th argument
%r8 used to pass 5th argument
%r9 used to pass 6th argument
%rax 1st return register
*/

/* int _atomic_and(int *ptr, int val); */
FUNCTION(_atomic_and)
    mov (%rdi), %eax
0:
    mov %eax, %ecx
    and %esi, %ecx
    lock
    cmpxchg %ecx, (%rdi)
    jnz 1f                  /* static prediction: branch forward not taken */
    ret
1:
    jmp 0b


/* int _atomic_or(int *ptr, int val); */
FUNCTION(_atomic_or)

    mov (%rdi), %eax
0:
    mov %eax, %ecx
    or  %esi, %ecx
    lock
    cmpxchg %ecx, (%rdi)
    jnz 1f                  /* static prediction: branch forward not taken */
    ret
1:
    jmp 0b

/* void arch_idle(); */
FUNCTION(arch_idle)
    pushf
    popq %rax
    andq $0x200, %rax
    test %rax, %rax
    je 1f                   /* don't halt if local interrupts are disabled */
    hlt
1:
    ret

