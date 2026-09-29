#import "HLOGreeter.h"

// Written for ARC, as an Xcode target's Objective-C is: without it this would leak, so it
// refuses to compile instead.
#if !__has_feature(objc_arc)
#error "HLOGreeter.m is compiled with ARC"
#endif

@implementation HLOGreeter

- (NSString *)greeting {
    return @"and from Objective-C";
}

@end
