#import <Foundation/Foundation.h>
#import "Smoothing.h"

// SwiftPM defines this for every C-family target of a package (B-77).
#if !SWIFT_PACKAGE
#error "Smoothing is compiled as a package target, with SWIFT_PACKAGE=1"
#endif

NSString *SmoothingStyleName(int style) {
    return style == 0 ? @"none" : [NSString stringWithFormat:@"level %d", style];
}
