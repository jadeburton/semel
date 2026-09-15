//
//  HermeticityTests.swift
//  SemelCore
//

import Foundation
import XCTest

/// B-02. A node's outputs are supposed to be a function of its declared inputs, and the
/// two ways code slips past that are launching a process of its own and reading the
/// environment. `LocalFileSystemTool` is the one place a tool may run — inside a sandbox,
/// with a scrubbed environment (see `LocalFileSystemToolTests`) — and the toolchain lookups
/// at launch are the one other process launch the design accepts. Everything else that
/// wants a subprocess or an environment variable has to explain itself here first.
///
/// A source scan rather than a lint rule, because it has to run where every other test
/// runs and fail the same way.
final class HermeticityTests: XCTestCase {

    /// The repository root, relative to this file: `swift test` runs from the package
    /// folder, not the root the other packages live under.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SemelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SemelCore
            .deletingLastPathComponent()   // repository root
    }

    /// Every package whose sources a node function can reach.
    private static let nodeSidePackages = ["SemelNodeKit", "SemelDatabaseModels", "SemelCore",
                                           "SemelSwift", "SemelClang", "SemelApple"]

    /// The files allowed to launch a process, each with the reason. Keep this short: an
    /// entry here is a declared hole in hermeticity.
    private static let filesAllowedToLaunchProcesses: [String: String] = [
        // The sandboxed runner itself: fresh directory, fixed PATH, HOME and TMPDIR inside
        // the sandbox, nothing inherited, deleted afterwards.
        "LocalFileSystemTool.swift":
            "the one sanctioned tool launcher",
        // The questions the toolchains put to the machine at launch — `xcrun --find` and
        // `<tool> --version` to register what is installed, the SDK queries the Swift
        // tools cache once per process — all run through this one generic runner. Not
        // part of any node's function, though the SDK path they yield is not an input
        // either, which B-47 records.
        "MachineQuery.swift":
            "launch-time questions to the machine",
        // `SEMEL_HOME` and `SEMEL_SOCKET`, read at launch to place the root and the socket
        // so a test-started server never opens the user's graph. Not a node input: nothing a
        // node function does depends on them.
        "SemelPaths.swift":
            "launch-time placement of the root and the server socket",
    ]

    /// What reaches outside a node's inputs. `Process(` also matches `Foundation.Process(`.
    private static let escapes = ["Process()", "ProcessInfo.processInfo", "getenv("]

    private static func swiftSources(under packageFolder: URL) throws -> [URL] {
        let sources = packageFolder.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func test_onlyTheSanctionedFilesLaunchProcessesOrReadTheEnvironment() throws {
        var offenders: [String] = []

        for package in Self.nodeSidePackages {
            let folder = Self.repositoryRoot.appendingPathComponent(package, isDirectory: true)
            for file in try Self.swiftSources(under: folder) {
                guard Self.filesAllowedToLaunchProcesses[file.lastPathComponent] == nil else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }
                    for escape in Self.escapes where code.contains(escape) {
                        offenders.append("\(package)/\(file.lastPathComponent):\(number + 1): \(code)")
                    }
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These reach outside a node's declared inputs. Route a tool through \
            LocalFileSystemTool, or add the file to the allowlist with a reason:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The allowlist names files that exist; a rename must not silently widen the net.
    func test_everyAllowlistedFileExists() throws {
        var found = Set<String>()
        for package in Self.nodeSidePackages {
            let folder = Self.repositoryRoot.appendingPathComponent(package, isDirectory: true)
            for file in try Self.swiftSources(under: folder) {
                found.insert(file.lastPathComponent)
            }
        }
        for name in Self.filesAllowedToLaunchProcesses.keys {
            XCTAssertTrue(found.contains(name), "allowlisted file no longer exists: \(name)")
        }
    }
}
