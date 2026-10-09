// SDKFingerprint.swift
// SemelNodeKit
//
// The SDK's contents as a machine fact (B-47). Every toolchain compiles against an SDK
// tree it names by path — `-sdk` for swiftc, `-isysroot` and `-L <sdk>/usr/lib` for clang —
// and what is behind that path is an input the input file system does not hold: a
// gigabyte of headers and stubs that belongs to the machine. The declared `sdkVersion`
// names which SDK it should be, but two machines can declare the same "26.5 (25F70)" and
// hold different files under it, one patched and one not.
//
// The fingerprint reaches the graph two ways, and each closes what the other cannot.
//
// - A node that reads the SDK folds it into its cache key through `Node.cacheKeyMaterial`
//   (`sdkCacheKeyMaterial`). That is what protects a cache shared between machines, and a
//   machine file that no longer describes the SDK: the key is taken from the tree the tool
//   will read when it runs, not from what a file says about it. But a key only stops a
//   wrong reuse; a node nothing schedules never recomputes it.
// - The toolchains declare it as a machine setting (`machineSettingKey`), so the writers of
//   `semel.machine.config` put it under each namespace whose tool reads the SDK. A changed
//   SDK is then a changed line in a pushed file, which changes what every `ConfigFilter`
//   over that namespace publishes, which reschedules every node reading it. That is what
//   makes an Xcode update, or an SDK edited in place, rebuild an already-built graph.
//
// Measured on Xcode 26.6's macOS SDK (32,345 files, 765 MB): a walk recording path, size
// and modification time takes 1.2 s cold and 0.4 s warm; hashing every file's content
// takes 4.4 s; hashing only SDKSettings takes 65 ms but sees no edited header. The walk is
// the answer, once per process per SDK. It is deliberately not cached in the database
// across launches: the only cheap invalidation signal would be the SDK directory's own
// modification time, which does not change when a file deep inside it does — a cache
// keyed on it would silently reopen the gap this closes.

import CryptoKit
import Foundation

/// The machine setting every SDK-reading namespace declares, which a machine file writer
/// fills with `sdkFingerprint(ofSDKAtPath:)` of the platform's SDK.
public let sdkFingerprintMachineSettingKey = "sdkFingerprint"

/// A fingerprint of every regular file under `root`: relative path, size and modification
/// time, sorted, hashed. Nil if there is no such directory. Walks every time; production
/// reads go through `sdkFingerprint(ofSDKAtPath:)`, which walks once per process.
///
/// Hashed with CryptoKit directly rather than `Sha256.hash`, which hands short inputs
/// back verbatim — right for content addressing, wrong for a digest that must always be
/// a digest.
public func sdkContentFingerprint(ofDirectory root: URL) -> String? {
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
    // Enumeration order is the file system's; the fingerprint must not be.
    lines.sort()

    let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Once per resolved path per process: the answer cannot change mid-build, and every
/// compile, preprocess and link asks it. Keyed by the resolved path because the path an
/// SDK is named by is a symlink (`MacOSX26.5.sdk -> MacOSX.sdk`) and two names for one tree
/// are one walk. Nodes process concurrently in phase 1, so the memo is locked; the walk
/// happens under the lock, so two nodes asking at once walk once.
final class SDKFingerprints {
    static let shared = SDKFingerprints(walk: sdkContentFingerprint(ofDirectory:))

    private let walk: (URL) -> String?
    private let lock = NSLock()
    private var byResolvedPath: [String: String?] = [:]

    /// `walk` is the fingerprint itself, a parameter so a test can count the walks.
    init(walk: @escaping (URL) -> String?) {
        self.walk = walk
    }

    func fingerprint(ofSDKAtPath path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        lock.lock(); defer { lock.unlock() }
        if let known = byResolvedPath[resolved.path] {
            return known
        }
        let answer = walk(resolved)
        byResolvedPath[resolved.path] = answer
        return answer
    }
}

/// Where every reader of the SDK fingerprint gets it: the nodes' cache-key material and the
/// toolchains' machine settings. A variable so a test can stand in a value without walking
/// the machine's SDK — the same seam shape as `FatalErrors.handler`.
public var sdkFingerprintProvider: (String) -> String? = { SDKFingerprints.shared.fingerprint(ofSDKAtPath: $0) }

/// The fingerprint of the SDK tree at `path`, walked at most once per process. Nil when
/// there is no directory there.
public func sdkFingerprint(ofSDKAtPath path: String) -> String? {
    sdkFingerprintProvider(path)
}

/// A node's contribution to its cache key for the SDK it reads: the name the configuration
/// knows it by and the fingerprint of the tree behind `path`. The name is part of the
/// material so two SDKs never share an entry even if their trees happened to fingerprint
/// alike. Nil when there is no SDK at `path`: the node fails on its own for want of one.
public func sdkCacheKeyMaterial(sdkNamed name: String, atPath path: String) -> String? {
    sdkFingerprint(ofSDKAtPath: path).map { "sdk=\(name):\($0)" }
}

/// The same for a tool told the SDK by path, `sdkPath` — the clang tools, ibtool — named by
/// the folder's own name, since the path is in the key already, on the configuration wire.
/// Nil when the configuration names no SDK, which is a build that reads none.
public func sdkCacheKeyMaterial(sdkPathIn properties: [String: String]) -> String? {
    guard let path = properties[sdkPathSettingKey] else {
        return nil
    }
    return sdkCacheKeyMaterial(sdkNamed: URL(fileURLWithPath: path).lastPathComponent, atPath: path)
}

/// The setting a tool told the SDK by path reads it from.
public let sdkPathSettingKey = "sdkPath"
