//
//  ToolNodeCacheKeyTests.swift
//  SemelCore
//
//  B-17. A node that runs a discovered tool compiles with whatever binary answers to the
//  version its configuration names, and a configuration cannot name the binary — so the
//  fingerprint discovery took of it has to reach the key through the node's
//  `cacheKeyMaterial`. A node type that runs a tool and forgets to declare it is a wrong
//  cache hit waiting for someone to reinstall a toolchain, and no test that names existing
//  types can notice a type nobody has written yet.
//
//  A source scan rather than a lint rule, for the reason `HermeticityTests` gives: it has
//  to run where every other test runs and fail the same way.
//
//  What the scan cannot see, for want of a rule that is exact rather than suggestive: it
//  reads whole files, so a type whose file also declares a *second* type with the material
//  reads as covered. Every tool node here is one type to a file, and the material is
//  declared either in that file or in an `extension` of the type elsewhere in its package
//  — which is what the scan looks for.
//

import Foundation
import XCTest

final class ToolNodeCacheKeyTests: XCTestCase {

    /// The repository root, relative to this file: `swift test` runs from the package
    /// folder, not the root the other packages live under.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SemelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SemelCore
            .deletingLastPathComponent()   // repository root
    }

    /// Every package whose sources may hold a node that runs a tool.
    private static let scannedPackages = ["SemelNodeKit", "SemelCore",
                                          "SemelSwift", "SemelClang", "SemelApple"]

    /// How a node reaches its tool. `ToolDiscovery` is the one place that builds a real
    /// executor, and this is the one way a node gets one from it.
    private static let runsATool = "ToolRunnerRegistry.instance.tool("

    private static func swiftSources(under packageFolder: URL) throws -> [URL] {
        let sources = packageFolder.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The node types a file declares: `struct X: Node`, however it is qualified.
    private static func nodeTypes(declaredIn text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            let words = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            guard let structIndex = words.firstIndex(of: "struct"),
                  words.count > structIndex + 2,
                  words[structIndex + 2].hasPrefix("Node") else {
                return nil
            }
            return String(words[structIndex + 1].drop(while: { $0 == " " }).prefix { $0 != ":" })
        }
    }

    private static func mentions(_ text: String, _ needle: String) -> Bool {
        text.components(separatedBy: "\n").contains { line in
            let code = line.trimmingCharacters(in: .whitespaces)
            return !code.hasPrefix("//") && code.contains(needle)
        }
    }

    /// Every node type that runs a tool, with the sources of the package it lives in.
    private static func toolRunningTypes() throws -> [(type: String, package: String, sources: [String])] {
        var found: [(type: String, package: String, sources: [String])] = []

        for package in scannedPackages {
            let folder = repositoryRoot.appendingPathComponent(package, isDirectory: true)
            let texts  = try swiftSources(under: folder).map { try String(contentsOf: $0, encoding: .utf8) }

            for text in texts where mentions(text, runsATool) {
                for type in nodeTypes(declaredIn: text) {
                    found.append((type: type, package: package, sources: texts))
                }
            }
        }
        return found
    }

    func test_everyNodeThatRunsAToolDeclaresTheToolBinaryInItsCacheKey() throws {
        var offenders: [String] = []

        for node in try Self.toolRunningTypes() {
            let declaringTheMaterial = node.sources.filter {
                Self.mentions($0, "struct \(node.type):") || Self.mentions($0, "extension \(node.type) ")
            }
            let declared = declaringTheMaterial.contains {
                Self.mentions($0, "func cacheKeyMaterial(input:") && Self.mentions($0, "toolBinaryCacheKeyMaterial")
            }
            if !declared {
                offenders.append("\(node.package).\(node.type)")
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            These run a discovered tool and do not declare the binary behind it in their \
            cache key. Return `toolBinaryCacheKeyMaterial(input:configurationPort:)` from \
            `cacheKeyMaterial`, or two builds of one tool version will share their entries:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The scan itself: a call site spelled another way, or a node type declared another
    /// way, would leave it finding nothing and passing for the wrong reason.
    func test_theScanFindsTheToolNodesThisTreeHas() throws {
        let types = Set(try Self.toolRunningTypes().map(\.type))

        XCTAssertTrue(types.isSuperset(of: ["ClangPreprocessor", "ClangCompiler", "ClangLinker",
                                            "AssetCatalogCompiler", "StringCatalogCompiler",
                                            "SwiftPackageReader", "SwiftCompiler", "SwiftLinker"]),
                      "the scan should see every node that runs a tool, found: \(types.sorted())")
    }
}
