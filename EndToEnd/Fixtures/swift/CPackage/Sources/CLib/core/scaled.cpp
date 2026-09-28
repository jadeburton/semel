// C++ in the C target: a function-local static with a constructor needs
// `___cxa_guard_acquire`, and `std::string` the C++ standard library, so the products
// linking CLib link only with the C++ runtime the converter says they need.
#include <string>
#include <clib.h>

int clib_scaled(int value) {
    static const std::string label = "scaled";
    return value * static_cast<int>(label.size());
}
