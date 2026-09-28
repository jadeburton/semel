// A module import, as every header of NetNewsWire's Objective-C targets opens: it needs
// clang modules, and without them clang stops at this line.
@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/// Holds its delegate weakly. A weak property can be synthesized only under ARC.
@interface OKOwner : NSObject

@property (nonatomic, weak, nullable) id delegate;

/// Whether a weak reference is nil once the object it named is gone: what ARC promises.
+ (BOOL)weakReferenceClears;

@end

NS_ASSUME_NONNULL_END
