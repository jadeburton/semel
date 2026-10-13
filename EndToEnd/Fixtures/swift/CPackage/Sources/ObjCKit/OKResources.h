@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// Reads the target's own resource bundle, as SwiftPM's Objective-C targets do.
@interface OKResources : NSObject

/// The text of `greeting.txt` in the bundle, nil when the bundle does not hold it.
+ (nullable NSString *)greeting;

@end

NS_ASSUME_NONNULL_END
