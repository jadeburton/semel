#include <stdio.h>
#include <clib.h>

int main(void) {
    printf("the answer is %d, twice %d\n", clib_answer(), clib_twice(clib_answer()));
    return 0;
}
