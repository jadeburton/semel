#include <stdio.h>
#include <greet.h>

// GREET_TIMES is the library's PRIVATE define: a build without it is a build that lost
// the define somewhere between the CMakeLists.txt and the compiler.
#ifndef GREET_TIMES
#error "GREET_TIMES is not defined"
#endif

void greet(const char *name) {
    for (int count = 0; count < GREET_TIMES; count++) {
        printf("Hello, %s!\n", name);
    }
}
