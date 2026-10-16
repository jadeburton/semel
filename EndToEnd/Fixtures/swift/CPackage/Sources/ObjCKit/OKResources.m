#import "OKResources.h"

// No import declares SWIFTPM_MODULE_BUNDLE: SwiftPM forces its accessor's header into
// every compile of a target with resources and Objective-C, and this does not compile
// without it.

@implementation OKResources

+ (nullable NSString *)greeting {
    NSURL *url = [SWIFTPM_MODULE_BUNDLE URLForResource:@"greeting" withExtension:@"txt"];
    if (url == nil) {
        return nil;
    }
    return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
}

@end
