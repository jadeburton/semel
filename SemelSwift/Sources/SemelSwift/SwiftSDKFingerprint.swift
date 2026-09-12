// SwiftSDKFingerprint.swift
// SemelSwift
//
// The SDK's contents as a cache-key input (B-47, the wide half).
//
// The Swift compiler and linker pass `-sdk <path>` and compile against whatever is behind
// it. The declared `sdkVersion` — version and build, checked against the machine — names
// which SDK that should be, but two machines can declare the same "26.5 (25F70)" and hold
// different files under it: one patched, one not. Their cache keys were identical and
// their artifacts were not. This fingerprints what is actually there and puts it in the
// key through `Node.cacheKeyMaterial`.
//
// Why a key part and not `toolDescriptor.recursiveHash`: the registry matches a config's
// whole descriptor against the installed tool's, so a registered hash would force every
// config file to declare it by hand — the thing B-47 rejected. A key part costs the user
// nothing to declare.
//
// What it does and does not close. A cache key can only stop a wrong reuse. An SDK edited
// in place under an already-built graph is still not rebuilt, because an unscheduled node
// never recomputes its key; making the SDK a graph input is B-03's job.
//
// Measured on Xcode 26.6's macOS SDK (32,345 files, 765 MB): a walk recording path, size
// and modification time takes 1.2 s cold and 0.4 s warm; hashing every file's content
// takes 4.4 s; hashing only SDKSettings takes 65 ms but sees no edited header. The walk is
// the answer, once per process. It is deliberately not cached in the database across
// launches: the only cheap invalidation signal would be the SDK directory's own
// modification time, which does not change when a file deep inside it does — a cache
// keyed on it would silently reopen the gap this closes.

import CryptoKit
import Foundation
import SemelNodeKit

/// A fingerprint of every regular file under `root`: relative path, size and modification
/// time, sorted, hashed. Nil if there is no such directory.
///
/// Hashed with CryptoKit directly rather than `Sha256.hash`, which hands short inputs
/// back verbatim — right for content addressing, wrong for a digest that must always be
/// a digest.
func sdkContentFingerprint(ofDirectory root: URL) -> String? {
    let resolved = root.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return nil
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let enumerator = FileManager.default.enumerator(at: resolved,
                                                          includingPropertiesForKeys: Array(keys),
                                                          options: []) else {
        return nil
    }

    let prefixLength = resolved.path.count + 1
    var lines: [String] = []
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
            continue
        }
        let relativePath = String(url.path.dropFirst(prefixLength))
        let size         = values.fileSize ?? 0
        // Microseconds: fine enough that an edit is not lost to rounding, coarse enough
        // to be stable across the two reads a test makes.
        let modified     = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000)
        lines.append("\(relativePath)\u{0}\(size)\u{0}\(modified)")
    }
    // Enumeration order is the file system's; the key must not be.
    lines.sort()

    let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

// Once per process, like the SDK path and version: the answer cannot change mid-build.
private let cachedSDKFingerprint: String? =
    resolveSDKPath().flatMap { sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: $0)) }

/// Where the Swift tools get the fingerprint. A variable so a test can stand in a value
/// without walking the machine's SDK — the same seam shape as `FatalErrors.handler`.
var sdkFingerprintProvider: () -> String? = { cachedSDKFingerprint }

/// The Swift tools' contribution to their cache key. Shared by the compiler and the
/// linker, the two nodes that pass `-sdk`.
func sdkCacheKeyMaterial() -> String? {
    sdkFingerprintProvider().map { "sdk=\($0)" }
}

extension SwiftCompiler {
    public func cacheKeyMaterial() throws -> String? {
        sdkCacheKeyMaterial()
    }
}

extension SwiftLinker {
    public func cacheKeyMaterial() throws -> String? {
        sdkCacheKeyMaterial()
    }
}
