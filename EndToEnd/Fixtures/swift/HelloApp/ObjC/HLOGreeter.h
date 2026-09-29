// An Objective-C class the app's Swift reaches through the bridging header. `@import`
// needs clang modules, as NetNewsWire's `NSOpenPanel+Extras.h` does.

@import Foundation;

NS_ASSUME_NONNULL_BEGIN

@interface HLOGreeter : NSObject

@property (nonatomic, readonly, copy) NSString *greeting;

@end

NS_ASSUME_NONNULL_END
