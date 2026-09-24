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
// Why a key part rather than a setting: a config file names the SDK, not what is inside
// it, and a fingerprint a user had to write by hand is one more thing to get wrong — what
// B-47 rejected. A key part costs the user nothing to declare. The tool binary's
// fingerprint reaches the key the same way (`toolBinaryCacheKeyMaterial`), from the
// descriptor discovery registers it on.
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

// Once per process per SDK, like the SDK path and version: the answer cannot change
// mid-build. Nodes process concurrently in phase 1, so the memo is locked.
private final class SDKFingerprints {
    static let shared = SDKFingerprints()
    private let lock = NSLock()
    private var byName: [String: String?] = [:]

    func fingerprint(sdk: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let known = byName[sdk] {
            return known
        }
        let answer = resolveSDKPath(sdk: sdk).flatMap { sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: $0)) }
        byName[sdk] = answer
        return answer
    }
}

/// Where the Swift tools get the fingerprint of a named SDK. A variable so a test can
/// stand in a value without walking the machine's SDK — the same seam shape as
/// `FatalErrors.handler`.
var sdkFingerprintProvider: (String) -> String? = { SDKFingerprints.shared.fingerprint(sdk: $0) }

/// The Swift tools' contribution to their cache key: the SDK the configuration names and
/// the fingerprint of what is behind it. Shared by the compiler and the linker, the two
/// nodes that pass `-sdk`. The name is part of the material so two SDKs never share an
/// entry even if their trees happened to fingerprint alike.
func sdkCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    let sdk = try configuredSDKName(input: input, configurationPort: configurationPort)
    return sdkFingerprintProvider(sdk).map { "sdk=\(sdk):\($0)" }
}

/// The `sdk` setting out of the configuration on the wire, or the default. Read from the
/// raw text rather than through the tool's configuration type, which requires every other
/// setting to be present — and the key has to be computable before that is known.
private func configuredSDKName(input: ProcessInput, configurationPort: String) throws -> String {
    guard let value = input.inputValues[configurationPort]?.values.first,
          case .value(let hash) = value else {
        return defaultSDKName
    }
    let properties = [String: String](plainText: try hash.resolveAsString())
    return properties["sdk"] ?? defaultSDKName
}

/// Everything a Swift tool reads outside its inputs: the SDK behind `-sdk`, and the binary
/// behind the tool version its configuration names (B-17). Each line stands on its own, so
/// a tool that finds only one of the two still declares it.
func swiftToolCacheKeyMaterial(input: ProcessInput, configurationPort: String) throws -> String? {
    let lines = [try sdkCacheKeyMaterial(input: input, configurationPort: configurationPort),
                 try toolBinaryCacheKeyMaterial(input: input, configurationPort: configurationPort)].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

extension SwiftCompiler {
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try swiftToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}

extension SwiftLinker {
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try swiftToolCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }
}
