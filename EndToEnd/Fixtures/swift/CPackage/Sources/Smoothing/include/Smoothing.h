// Covered by this target's own module map, as CodeEditTextViewObjC's header is: the
// source that includes it is preprocessed as the module being built, and clang marks the
// header's text as that module's (B-77).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The style's name, from Objective-C that loads Foundation as a module.
NSString *SmoothingStyleName(int style);

NS_ASSUME_NONNULL_END
