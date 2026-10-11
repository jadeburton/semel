// CacheServerDependencyRuleTests.swift
// SemelCacheServerTests
//
// AGENTS.md's rule, held from the manifests: `semel-cache` links `SemelCache`,
// `SemelTransport`, `SemelProtocol` and `SemelNodeKit`, and never `SemelCore`. A server that
// linked the engine to read an entry would carry the graph, the toolchain plugins and the
// graph's database; the compiler would not mind, so this test does.
//
// The manifests are read as text: a test cannot run `swift package dump-package` from
// inside `swift test`, which holds the package's lock. What is read is narrow — a target's
// name and the names in its `dependencies:` list — and a manifest written in another shape
// fails here rather than passing unread.

import Foundation
import XCTest

final class CacheServerDependencyRuleTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // semel-cache
        .deletingLastPathComponent()

    /// What the server's targets may name. `SemelCacheServer` is its own library.
    private static let allowed: Set<String> = ["SemelCacheServer", "SemelCache", "SemelTransport", "SemelProtocol", "SemelNodeKit"]

    func test_theServerLinksTheSharedLibrariesAndNeverTheEngine() throws {
        let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"), encoding: .utf8)

        for target in ["semel-cache", "SemelCacheServer"] {
            let dependencies = try XCTUnwrap(Self.dependencies(ofTarget: target, in: manifest), "no target \(target) in Package.swift")
            XCTAssertFalse(dependencies.isEmpty, "\(target)'s dependencies were not read")
            XCTAssertEqual(dependencies.subtracting(Self.allowed), [], "\(target) links more than the shared libraries")
        }
        let transport = try XCTUnwrap(Self.dependencies(ofTarget: "SemelTransport", in: manifest))
        XCTAssertEqual(transport, ["SemelProtocol"], "the transport links the protocol and nothing of a server")
    }

    /// The libraries the server links do not reach the engine either.
    func test_noLibraryTheServerLinksDependsOnTheEngine() throws {
        for package in ["SemelCache", "SemelProtocol", "SemelNodeKit", "SemelDatabaseModels"] {
            let manifest = try String(contentsOf: Self.repositoryRoot.appendingPathComponent(package).appendingPathComponent("Package.swift"),
                                      encoding: .utf8)
            for engine in ["SemelCore", "SemelServer", "SemelCLI"] {
                XCTAssertFalse(manifest.contains("\"\(engine)\""), "\(package) names \(engine)")
                XCTAssertFalse(manifest.contains("../\(engine)"), "\(package) names \(engine)")
            }
        }
    }

    /// The quoted names in the `dependencies: [ … ]` of the target named `target`: bare
    /// target names and the `name:` of each product.
    static func dependencies(ofTarget target: String, in manifest: String) -> Set<String>? {
        // A target's name is followed by its list; a product's name, which may be the same
        // word, by `targets:`.
        let pattern = "name:\\s*\"\(NSRegularExpression.escapedPattern(for: target))\",\\s*dependencies:\\s*\\["
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: manifest, range: NSRange(manifest.startIndex..., in: manifest)),
              let matched = Range(match.range, in: manifest) else {
            return nil
        }
        let afterName = manifest[matched.upperBound...]
        // The list ends at the bracket that closes it: count square brackets from the one
        // that opened it.
        var depth = 1
        var index = afterName.startIndex
        while index < afterName.endIndex, depth > 0 {
            switch afterName[index] {
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
            index = afterName.index(after: index)
        }
        let list = afterName[afterName.startIndex..<index]
        var names: Set<String> = []
        var remaining = list[...]
        while let open = remaining.firstIndex(of: "\"") {
            let rest = remaining[remaining.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else {
                break
            }
            let quoted = String(rest[..<close])
            let before = remaining[..<open]
            // `.product(name: "X", package: "Y")` names X; the package is where X comes from.
            if !before.hasSuffix("package: ") {
                names.insert(quoted)
            }
            remaining = rest[rest.index(after: close)...]
        }
        return names
    }
}
