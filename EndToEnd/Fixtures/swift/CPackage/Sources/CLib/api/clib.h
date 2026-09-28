#ifndef CLIB_H
#define CLIB_H

#ifdef __cplusplus
extern "C" {
#endif

int clib_answer(void);
int clib_twice(int value);
/// Through Foundation, from C (core/label.c).
int clib_label_length(void);
/// Through zlib, linked on macOS only (core/label.c).
int clib_has_zlib(void);
/// C++ (core/scaled.cpp).
int clib_scaled(int value);
/// Assembly, preprocessed (asm/offset.S) and not (asm/base.s).
int clib_asm_offset(void);
int clib_asm_base(void);

#ifdef __cplusplus
}
#endif

#endif
