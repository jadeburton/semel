#include "compress.h"

int squeeze_run_count(const char *text) {
    int runs = 0;
    char previous = 0;
    for (const char *character = text; *character != 0; character++) {
        if (*character != previous) {
            runs++;
        }
        previous = *character;
    }
    return runs;
}
