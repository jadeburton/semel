// One level down: its sibling header beside it, another a folder further down, and the
// public header by search path.
#include <clib.h>
#include "answer_private.h"
#include "detail/constants.h"

int clib_answer(void) {
    return clib_private_answer();
}

int clib_private_answer(void) {
    return CLIB_ANSWER_CONSTANT;
}
