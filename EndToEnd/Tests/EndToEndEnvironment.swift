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

    /// Short on purpose: sockets live under it, and a Unix-domain socket path is limited
    /// to 103 bytes.
    static func newRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
