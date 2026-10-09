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
// The fingerprint is the SHA-256 of the binary's bytes, symlinks resolved, and nothing
// else. Not its path: two machines keep one toolchain at two places —
// `/Applications/Xcode.app` and `/Applications/Xcode_26_6.app` are the same download —
// and a fingerprint carrying the path can never let them share an entry, which is the
// whole shape a cache server (B-30) needs. Not its size and modification time either:
// those describe a binary only until something restores a patched one over it with the
// mtime preserved — `cp -p`, `rsync -t`, an unpacked archive — at which point a key says
// nothing changed and hands back the other binary's output. The bytes have neither hole:
// equal bytes are the same compiler wherever it sits, and different bytes are a different
// compiler however it was installed.
//
// What that costs, measured on Xcode 26.6 with a warm page cache: 195 ms for `clang`
// (141 MB), 226 ms for `swift-frontend` (171 MB), under 1 ms each for `actool` and
// `xcstringstool` — 424 ms for the five tools the toolchains find here. It is paid once
// per process, inside discovery, beside the `xcrun --find` and `--version` subprocesses
// that already run there, and a server pays it at launch rather than per build. The hash
// is memoised by resolved path, because `swiftc` and `swift` are two names for one binary
// and 171 MB is not worth reading twice.
//
// Fingerprinting the SDK tree is the other half of the same question and is answered
// differently (`SDKFingerprint`): 765 MB of small files cost 4.4 s to hash and 1.2 s
// to walk, so that one records paths, sizes and modification times. A handful of binaries
// is affordable where a whole SDK is not.
//
// What it does and does not close. The fingerprint is taken when the tool is registered,
// like the version recorded beside it: a binary replaced under a running engine is
// described by the snapshot discovery took, and making the tool a graph input is B-03's
// job. A cache key can only stop a wrong reuse; it never causes a recomputation, because
// an unscheduled node never rebuilds its key.

import CryptoKit
import Foundation

/// The SHA-256 of the bytes of the binary at `path`, with symlinks resolved — `swiftc` in
/// an Apple toolchain points at `swift-frontend`, and the frontend is the file that does
/// the work. Nil when there is no regular file there.
///
/// Read in chunks: the file is hundreds of megabytes and there is no reason for any of it
/// to be resident at once. Hashed with CryptoKit directly rather than `Sha256.hash`, which
/// hands short inputs back verbatim — right for content addressing, wrong for a digest
/// that must always be a digest.
func toolBinaryContentFingerprint(ofFileAt path: String) -> String? {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
          values.isRegularFile == true,
          let handle = try? FileHandle(forReadingFrom: resolved) else {
        return nil
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Once per resolved path per process. Two tool names reaching one binary hash it once,
/// and a second discovery pass — a test's, a reset's — reads nothing. Locked because
/// nothing promises discovery is the only caller on the only thread.
private final class ToolBinaryFingerprints {
    static let shared = ToolBinaryFingerprints()
    private let lock = NSLock()
    private var byResolvedPath: [String: String?] = [:]

    func fingerprint(ofFileAt path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        lock.lock(); defer { lock.unlock() }
        if let known = byResolvedPath[resolved] {
            return known
        }
        let answer = toolBinaryContentFingerprint(ofFileAt: resolved)
        byResolvedPath[resolved] = answer
        return answer
    }
}

/// What `ToolDiscovery` records against a tool it located: the fingerprint of the binary
/// at that path, hashed at most once per process however many tools reach it.
public func toolBinaryFingerprint(ofFileAt path: String) -> String? {
    ToolBinaryFingerprints.shared.fingerprint(ofFileAt: path)
}

/// What a descriptor records for a tool: its binary's fingerprint, folded with the
/// fingerprint of what the tool runs beside it when it runs anything (B-80). A tool with
/// no companions records its binary's fingerprint as it stands. Nil when the binary could
/// not be read, which fails open as the binary's own fingerprint does.
public func toolFingerprint(binary: String?, companions: String?) -> String? {
    guard let binary else {
        return nil
    }
    guard let companions else {
        return binary
    }
    let digest = SHA256.hash(data: Data("binary=\(binary)\ncompanions=\(companions)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// A tool node's contribution to its cache key: the fingerprint of the binary behind the
/// tool its configuration names. Every node that runs a discovered tool returns this from
/// `cacheKeyMaterial`, so that two binaries a configuration cannot tell apart key
/// differently.
///
/// Nil when the configuration names no tool, or names one this machine does not have — a
/// node asking for a tool that is not installed fails when it is processed, with a message
/// naming what is available, and a key it never uses is worth nothing. It is nil for a
/// registered tool whose binary could not be read as well: that fails open, keying as
/// though the tool were absent rather than refusing to build.
///
/// The configuration is read from the raw text rather than through the node's own
/// configuration type, which requires every other setting to be present: the key has to be
/// computable before that is known.
public func toolBinaryCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    guard case .value(let hash)? = try input.onlyWire(onOptionalPort: configurationPort)?.value else {
        return nil
    }
    return toolBinaryCacheKeyMaterial(configuration: [String: String](plainText: try hash.resolveAsString()))
}

/// The same, for a caller that has already resolved the configuration text — reading it
/// twice would read the blob from the object store and verify its hash twice.
public func toolBinaryCacheKeyMaterial(configuration properties: [String: String]) -> String? {
    guard let identity = ToolDescriptor.Identity(properties: properties),
          let fingerprint = ToolRunnerRegistry.instance.registeredDescriptor(matching: identity)?.recursiveHash else {
        return nil
    }
    // The name is part of the material so two tools never share an entry even if their
    // binaries happened to hash alike. The rest of the identity is already in the key: it
    // arrives on the configuration wire.
    return "tool=\(identity.name):\(fingerprint)"
}
