#import "OKOwner.h"

// The preprocessor sees ARC too: FMDB picks its retain and release macros by this test.
#if !__has_feature(objc_arc)
#error "ObjCKit is ARC code and must be compiled with -fobjc-arc"
#endif

@implementation OKOwner

+ (BOOL)weakReferenceClears {
    OKOwner *owner = [OKOwner new];
    @autoreleasepool {
        NSObject *delegate = [NSObject new];
        owner.delegate = delegate;
        if (owner.delegate != delegate) {
            return NO;
        }
    }
    return owner.delegate == nil;
}

@end
