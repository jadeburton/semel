// Assembly the preprocessor runs over, as in PLCrashAsyncThread_current.S of
// PLCrashReporter: a macro names the symbol, and the defines of the target reach it as
// they reach its C.
#ifndef CLIB_ANSWER
#error "the define CLIB_ANSWER did not reach the preprocessor of the assembly"
#endif

#define CLIB_ASM_OFFSET _clib_asm_offset

    .text
    .globl CLIB_ASM_OFFSET
    .p2align 2
CLIB_ASM_OFFSET:
#if defined(__arm64__)
    mov w0, #2
    ret
#elif defined(__x86_64__)
    movl $2, %eax
    ret
#else
#error "no clib_asm_offset for this architecture"
#endif
