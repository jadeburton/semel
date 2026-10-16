// BuildEngine+SharedCache.swift
// SemelCore
//
// The engine's shared cache (B-153): which one is in force, and what `cache` reports of it.
// What a lookup and a write do with it is in the two hooks (`Cache.swift`); how it reaches
// the server is the `RemoteCache` the host hands it, which the engine never sees inside —
// the engine speaks no frames.

import Foundation
import SemelCache

extension BuildEngine {

    /// The shared cache in force, nil when the home names none: then the engine is its
    /// local cache alone, exactly as without this feature.
    public var sharedCache: SharedCache? {
        installedSharedCache
    }

    /// Puts `cache` in force, started, in place of the one before, which is stopped — its
    /// queue is not written: the entries in it were meant for a server the home no longer
    /// names. Nil goes back to the local cache alone.
    public func useSharedCache(_ cache: SharedCache?) {
        let previous = installedSharedCache
        installedSharedCache = cache
        previous?.stop()
        cache?.start()
    }
}

extension SharedCacheLookup {

    /// The word the engine's debug log gives a lookup that came to no hit.
    var debugName: String {
        switch self {
        case .hit:
            return "hit"
        case .miss:
            return "miss"
        case .declined(_, let cost, let estimate):
            return "declined (built in \(cost) ms, fetched in \(String(format: "%.1f", estimate)) ms)"
        case .failed(let reason):
            return "failed (\(reason))"
        case .unavailable:
            return "unavailable"
        }
    }
}
