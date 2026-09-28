// Assembly as it is, with no preprocessing phase: arm64, which every build here is for.
    .text
    .globl _clib_asm_base
    .p2align 2
_clib_asm_base:
    mov w0, #40
    ret
