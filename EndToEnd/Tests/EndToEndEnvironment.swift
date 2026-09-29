//
//  EndToEndEnvironment.swift
//  SemelEndToEndTests
//
//  The three environment variables this target reads, and where things are. Nothing
//  else in the repository reads these.
//

import Foundation

enum EndToEndEnvironment {

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// `SEMEL_E2E_EXTERNAL=1`: run the external projects. Off, they report as skipped, so
    /// a plain `swift test` is fast and offline.
    static var runsExternal: Bool { environment["SEMEL_E2E_EXTERNAL"] == "1" }

    /// `SEMEL_E2E_KEEP=1`: keep a run's root and print its path.
    static var keepsRoots: Bool { environment["SEMEL_E2E_KEEP"] == "1" }

    /// `SEMEL_E2E_CACHE`: where pinned checkouts are kept between runs.
    static var cacheDirectory: URL {
        if let path = environment["SEMEL_E2E_CACHE"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("semel/end-to-end", isDirectory: true)
    }

    /// `EndToEnd/Fixtures`, found from this source file: the tests run from the
    /// repository, and the fixtures are part of it.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EndToEnd/Tests
            .deletingLastPathComponent()   // EndToEnd
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// The repository root, found from this source file, for the roster entry that builds
    /// Semel with Semel (B-78).
    static var repositoryRoot: URL {
        fixtures
            .deletingLastPathComponent()   // EndToEnd
            .deletingLastPathComponent()   // repository root
    }

    /// `SEMEL_E2E_ROOT`: the folder the run roots are made under, `/tmp/semel-tests` unless
    /// set. The nightly sets one of its own per run: its runner is also a workstation, and
    /// a developer's or an agent's own run under the default folder would otherwise share
    /// it with the nightly — which once removed the folder under a live run and failed its
    /// own cleanup on the files that run kept writing (2026-09-29).
    static var rootBase: URL {
        if let path = environment["SEMEL_E2E_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: "/tmp/semel-tests", isDirectory: true)
    }

    /// Short on purpose: sockets live under it, and a Unix-domain socket path is limited
    /// to 103 bytes.
    static func newRoot() throws -> URL {
        let base = rootBase
        removeStaleSiblings(under: base)
        let root = base.appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An interrupted run leaves its root behind, and `SEMEL_E2E_KEEP=1` keeps one on
    /// purpose; a day is long enough to inspect either before it is swept. Keyed on
    /// creation date, not modification date: on APFS a directory's modification date
    /// moves only when a direct child is added or removed, so a live root that writes
    /// deeper than its top level would look stale by that measure while still in use.
    /// Best effort: a listing or removal that fails leaves the entry in place, and
    /// nothing created within the cutoff is touched.
    private static func removeStaleSiblings(under directory: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else {
            return
        }
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = values.creationDate,
                  creationDate < cutoff else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
