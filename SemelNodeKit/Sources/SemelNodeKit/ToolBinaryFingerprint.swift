// ToolBinaryFingerprint.swift
// SemelNodeKit
//
// Which binary a tool descriptor stands for, as a cache-key input (B-17).
//
// A descriptor names a tool by the version the tool reports, and a version is only what a
// binary says about itself: a compiler built from source calls itself the release it
// branched from, and a toolchain reinstalled with a patch reports the version it patched.
// Two such binaries agree on every field a configuration can declare, so without this
// their nodes share a cache key and one binary's objects come back for the other.
//
// What is fingerprinted: the tool's path with symlinks resolved, its size and its
// modification time. Resolving matters — `swiftc` in an Apple toolchain is a symlink to
// `swift-frontend`, and the frontend is the binary that does the work — and the resolved
// path is itself part of the answer, so selecting another Xcode changes the fingerprint
// even when the two toolchains hold identical files.
//
// Why not the binary's content. Measured on Xcode 26.6 (`swiftc` 171 MB, `clang` 141 MB,
// `actool` 92 KB) with a warm page cache: path, size and modification time cost 0.05-0.8 ms
// per tool, a content hash 175-211 ms for the large two. Discovery fingerprints every
// installed tool at launch, so content hashing would buy a slower launch and a page cache
// emptied of everything else. This is the trade `SwiftSDKFingerprint` already makes for
// the SDK tree.
//
// What it does and does not close. The fingerprint is taken when the tool is registered,
// like the version recorded beside it: a binary replaced under a running engine is
// described by the snapshot discovery took, and making the tool a graph input is B-03's
// job. A cache key can only stop a wrong reuse; it never causes a recomputation, because
// an unscheduled node never rebuilds its key.

import CryptoKit
import Foundation

/// A fingerprint of the binary at `path`: its path with symlinks resolved, its size and
/// its modification time, hashed. Nil when there is no regular file there.
///
/// Hashed with CryptoKit directly rather than `Sha256.hash`, which hands short inputs back
/// verbatim — right for content addressing, wrong for a digest that must always be a
/// digest.
public func toolBinaryFingerprint(ofFileAt path: String) -> String? {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard let values = try? resolved.resourceValues(forKeys: keys), values.isRegularFile == true else {
        return nil
    }
    let size = values.fileSize ?? 0
    // Microseconds: fine enough that a replacement is not lost to rounding, coarse enough
    // to be stable across the two reads a test makes.
    let modified = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000)

    let digest = SHA256.hash(data: Data("\(resolved.path)\u{0}\(size)\u{0}\(modified)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// A tool node's contribution to its cache key: the fingerprint of the binary behind the
/// tool its configuration names. Every node that runs a discovered tool returns this from
/// `cacheKeyMaterial`, so that two binaries a configuration cannot tell apart key
/// differently.
///
/// Nil when the configuration names no tool, or names one this machine does not have — a
/// node asking for a tool that is not installed fails when it is processed, with a message
/// naming what is available, and a key it never uses is worth nothing.
///
/// The configuration is read from the raw text rather than through the node's own
/// configuration type, which requires every other setting to be present: the key has to be
/// computable before that is known.
public func toolBinaryCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    guard let value = input.inputValues[configurationPort]?.values.first,
          case .value(let hash) = value else {
        return nil
    }
    let properties = [String: String](plainText: try hash.resolveAsString())
    guard let identity = ToolDescriptor.Identity(properties: properties),
          let fingerprint = ToolRunnerRegistry.instance.registeredDescriptor(matching: identity)?.recursiveHash else {
        return nil
    }
    // The name is part of the material so two tools never share an entry even if their
    // binaries happened to fingerprint alike. The rest of the identity is already in the
    // key: it arrives on the configuration wire.
    return "tool=\(identity.name):\(fingerprint)"
}
