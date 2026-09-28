#include <stdio.h>
#include <clib.h>

int main(void) {
    printf("the answer is %d, twice %d\n", clib_answer(), clib_twice(clib_answer()));
    // Linked with what CLib asks for, though nothing here names a framework.
    printf("label %d, scaled %d, assembled %d\n", clib_label_length(), clib_scaled(7), clib_asm_base() + clib_asm_offset());
    return 0;
}
