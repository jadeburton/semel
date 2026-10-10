// SwiftCompilerPlugins.swift
// SemelSwift
//
// What `swiftc` runs beside itself to expand a macro, as part of the compiler's
// fingerprint (B-80).
//
// A macro is code the compiler runs while it compiles. A package's own macro is built by
// the graph and reaches the compile on a wire (`SwiftCompiler.macroExecutables`), so its
// hash is in the key like any input's. A macro the toolchain ships is not: `@Observable`
// is expanded by `libObservationMacros.dylib` under the toolchain's `lib/swift/host/plugins`,
// which the driver puts on `-plugin-path` by default, and `@Model` by
// `libSwiftDataMacros.dylib` under the platform's `Developer/usr/lib/swift/host/plugins`,
// which the driver hands to the platform's `swift-plugin-server` through
// `-external-plugin-path`, the platform found from the `-sdk` path. Neither needs a flag
// here — the sandbox hides nothing of the machine's toolchain — but neither is a byte of
// `swift-frontend` either, so a toolchain whose plugins changed while its frontend did
// not would key a compile like the one before. The fingerprint the descriptor carries
// covers them.
//
// What is fingerprinted: everything under the toolchain's `lib/swift/host` — the plugins,
// the in-process plugin server and the swift-syntax libraries the plugins link — and its
// `local/lib/swift/host/plugins`; and for every platform beside the toolchain, its two
// plugin folders and its `swift-plugin-server`. Every platform rather than the one being
// built: discovery takes the fingerprint before any configuration names an SDK, and a
// descriptor is per tool, not per SDK. A platform installed or removed therefore moves
// every Swift key once, which is the cost of not knowing at discovery which platform a
// build is for. Paths are recorded relative to the toolchain and to the platforms folder.
//
// Each file is recorded by its path, size and modification time, not its bytes — the
// scheme the SDK's fingerprint uses (`sdkContentFingerprint`), for the reason it does.
// Discovery runs as `semelserv` starts, before it listens, and a client that started the
// server waits for it: reading 85 MB of plugins and libraries there is a cost every start
// pays on a cold disk, where the walk is a hundredth of a second. What the key needs from
// these files is that a different file is a different line, and a plugin replaced by an
// update or a patch has a new size or modification time; the frontend's own bytes, which
// are hashed, already tell two compilers of one version apart. A plugin restored over
// another with its timestamp kept and its size unchanged would go unseen, which is the
// gap the SDK's fingerprint accepts too.
//
// Measured on Xcode 26.6 on an M4: 137 files, 85 MB. Their bytes took 0.6 s from a copy
// not yet in the page cache and 0.44 s warm (`shasum`); the walk takes 0.01 s.

import CryptoKit
import Foundation
import SemelNodeKit

enum SwiftCompilerPlugins {

    /// The fingerprint of the plugins the compiler at `toolPath` runs, or nil when there
    /// are none to be found. `toolPath` is what discovery located — `…/usr/bin/swiftc` —
    /// and the toolchain is the folder above its `bin`. The platforms are the developer
    /// folder's, found from the toolchain's path rather than asked of `xcrun`, which would
    /// be one more subprocess before the server listens.
    ///
    /// ISSUE: a toolchain outside a developer folder's `Toolchains` — a swift.org one in
    /// `/Library/Developer/Toolchains` — finds no platforms this way, and its fingerprint
    /// covers its own plugins alone, though the platform's still expand `@Model`.
    static func fingerprint(ofToolAt toolPath: String) -> String? {
        let toolchain = URL(fileURLWithPath: toolPath).resolvingSymlinksInPath()
            .deletingLastPathComponent()   // bin
            .deletingLastPathComponent()   // usr
        return fingerprint(toolchain: toolchain, platforms: platformsFolder(besideToolchain: toolchain))
    }

    /// `<developer>/Platforms` for a toolchain at `<developer>/Toolchains/<name>.xctoolchain/usr`,
    /// nil for a toolchain anywhere else.
    static func platformsFolder(besideToolchain toolchain: URL) -> URL? {
        let components = toolchain.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "Toolchains"), index > 0 else {
            return nil
        }
        let developer = NSString.path(withComponents: Array(components[..<index]))
        return URL(fileURLWithPath: developer, isDirectory: true).appendingPathComponent("Platforms", isDirectory: true)
    }

    /// The fingerprint of the plugin files under `toolchain` — a toolchain's `usr` — and
    /// under each `.platform` in `platforms`, nil when there is none.
    static func fingerprint(toolchain: URL, platforms: URL?) -> String? {
        var lines: [String] = []
        for relative in toolchainPaths {
            lines += fileLines(at: toolchain.appendingPathComponent(relative), labelled: "toolchain/" + relative)
        }
        if let platforms {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: platforms.path)) ?? []
            for platform in names.filter({ $0.hasSuffix(".platform") }).sorted() {
                for relative in platformPaths {
                    let path = platform + "/" + relative
                    lines += fileLines(at: platforms.appendingPathComponent(path), labelled: "platforms/" + path)
                }
            }
        }
        guard !lines.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Under a toolchain's `usr`.
    static let toolchainPaths = ["lib/swift/host", "local/lib/swift/host/plugins"]

    /// Under a `.platform`.
    static let platformPaths = ["Developer/usr/lib/swift/host/plugins",
                                "Developer/usr/local/lib/swift/host/plugins",
                                "Developer/usr/bin/swift-plugin-server"]

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                 .contentModificationDateKey]

    /// One line per regular file at or under `url`: its path under `label`, its size and
    /// its modification time. A link is recorded as the link it is, by what it names,
    /// since the file it names is recorded where it is. Sorted, since the file system's
    /// enumeration order is not the key's.
    private static func fileLines(at url: URL, labelled label: String) -> [String] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            return line(for: url, labelled: label).map { [$0] } ?? []
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return []
        }
        let prefix = url.standardizedFileURL.path + "/"
        var lines: [String] = []
        for case let item as URL in enumerator {
            let relative = String(item.standardizedFileURL.path.dropFirst(prefix.count))
            if let line = line(for: item, labelled: label + "/" + relative) {
                lines.append(line)
            }
        }
        return lines.sorted()
    }

    private static func line(for url: URL, labelled label: String) -> String? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
            return nil
        }
        if values.isSymbolicLink == true {
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return "\(label)\u{0}link\u{0}\(target)"
        }
        guard values.isRegularFile == true else {
            return nil
        }
        let size     = values.fileSize ?? 0
        // Microseconds, as the SDK's fingerprint records them.
        let modified = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000_000)
        return "\(label)\u{0}file\u{0}\(size)\u{0}\(modified)"
    }
}
