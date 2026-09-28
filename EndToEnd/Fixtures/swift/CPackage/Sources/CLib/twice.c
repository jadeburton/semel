// At the top of the target, beside the folders the rest sit in.
#include <clib.h>
// Found only by cSettings' .headerSearchPath("core/detail").
#include <constants.h>

#ifndef CLIB_ANSWER_CONSTANT
#error "constants.h by .headerSearchPath was not the one included"
#endif

#ifndef CLIB_ANSWER
#error "cSettings' .define(\"CLIB_ANSWER\") did not reach the preprocessor"
#endif

#ifdef CLIB_ON_WINDOWS
#error "a define conditional on Windows reached a macOS build"
#endif

int clib_twice(int value) {
    return value * 2;
}
