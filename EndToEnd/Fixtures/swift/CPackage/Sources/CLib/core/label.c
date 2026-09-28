// Calls into Foundation from C, as PLCrashReporter's `CFUUIDCreate` does: the
// CoreFoundation symbols come from `-framework Foundation`, which only the manifest's
// `.linkedFramework("Foundation")` asks for. Without it the link fails on
// `___CFConstantStringClassReference` and `_CFStringGetLength`.
#include <CoreFoundation/CoreFoundation.h>
// And from zlib, which `.linkedLibrary("z", .when(platforms: [.macOS]))` asks for on this
// platform only.
#include <zlib.h>
#include <clib.h>

int clib_label_length(void) {
    return (int)CFStringGetLength(CFSTR("answer"));
}

int clib_has_zlib(void) {
    return zlibVersion()[0] != '\0';
}
