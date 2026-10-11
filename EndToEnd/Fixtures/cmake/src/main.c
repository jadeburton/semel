#include <stdlib.h>
#include <greet.h>

// GREET_TIMES is PRIVATE to the library and must not reach the executable.
#ifdef GREET_TIMES
#error "GREET_TIMES leaked out of the library"
#endif

int main(int argc, const char *argv[]) {
    greet(argc > 1 ? argv[1] : "world");
    return EXIT_SUCCESS;
}
