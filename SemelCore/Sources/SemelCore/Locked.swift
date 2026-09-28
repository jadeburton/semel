//
//  Locked.swift
//  semel
//

import Foundation

/// A property read and written under a lock of its own.
///
/// For the engine's reporters: a server installs them once its handler exists, which is
/// after `start()` has set the loop running, and the loop calls them from its task. A
/// closure is two words, so a read concurrent with a write can pair one closure's
/// function with another's context — undefined, not merely stale. Only whole-value reads
/// and writes are guarded; a read-modify-write through the wrapper is two accesses.
///
/// Public only because the reporters it wraps are: Swift will not let a public property
/// use an internal wrapper.
@propertyWrapper
public final class Locked<Value> {

    private let lock = NSLock()
    private var value: Value

    public init(wrappedValue: Value) {
        value = wrappedValue
    }

    public var wrappedValue: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
