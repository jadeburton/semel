//
//  DictionaryOrderTests.swift
//  SemelCore
//

import Foundation
import XCTest

/// B-04. A `Dictionary`'s iteration order is seeded per process, so a walk of one gives a
/// different answer in every run of the engine. Where that answer reaches a command line,
/// a file's bytes, a formula, a cache key or a line a person reads, the build stops being
/// a function of its inputs — two processes building the same tree disagree, and the
/// disagreement moves.
///
/// Most dictionaries here are accumulated into, which is safe whatever the order, so a
/// blanket ban would be noise. This is the middle course: a scan for the two shapes that
/// turn a dictionary into a sequence, with every existing one classified. A hit that is
/// not in the allowlist is a walk nobody has classified yet — sort it, or add it here with
/// the reason its order cannot escape.
///
/// A source scan rather than a lint rule, for the reason `HermeticityTests` gives: it has
/// to run where every other test runs and fail the same way.
///
/// Three order-dependent shapes are deliberately out of scope, because none of them is
/// about the order of a sequence: `dict.values.first` on a port the formula wires exactly
/// once, a dictionary gathered into a `Set` — a membership question, and a set's own order
/// is a scan of its own — and an unstable `sort` over keys that tie.
final class DictionaryOrderTests: XCTestCase {

    /// The repository root, relative to this file.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SemelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SemelCore
            .deletingLastPathComponent()   // repository root
    }

    /// Every folder of non-test sources a build runs through, relative to the root.
    private static let scannedFolders = [
        "SemelNodeKit/Sources", "SemelDatabaseModels/Sources", "SemelCore/Sources",
        "SemelSwift/Sources", "SemelClang/Sources", "SemelApple/Sources",
        "semel/CommandInterpreter", "semel/Server", "semel/Transport", "semel-swift/Library",
    ]

    /// The walks that need no sort, each with why its order cannot reach anything a build
    /// produces. Keyed by the file's name and the text walked rather than by line, so a
    /// walk that moves keeps its entry and a new walk earns its own.
    ///
    /// Three kinds of entry are here: a walk of an array that merely looks like a walk of
    /// a dictionary, a walk that accumulates into a dictionary or a set (where only the
    /// result is kept, and it is the same result in any order), and a walk whose order is
    /// imposed again further down.
    private static let classifiedWalks: [String: String] = [
        // ── arrays of pairs: ordered already, by whoever built them ──────────────
        "ClangPreprocessor.swift: inputs.headerFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SwiftCompiler.swift: moduleMapFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SwiftLinker.swift: libraryFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SwiftFormulaConverter.swift: externalPackages":
            "an array, sorted by package folder so a name conflict resolves the same way twice",
        "SwiftPackageReader.swift: ancestors":
            "an array, built longest path first so the most specific prefix matches",
        "XcodeFormulaEmitter.swift: sourceFolders":
            "an array, in the order the project file lists the target's folders",
        "ProjectFinder.swift: folderManifests":
            "an array of the decoded manifests",
        "GeneratedFiles.swift: platformSettings(toolName: entry.toolName, platform: platform,":
            "an array of pairs the function returns in the order it states them",
        "Preparation.swift: [(GeneratedFiles.formulaFileName, formula), (GeneratedFiles.configFileName, config)]":
            "a literal array of the two files to write",
        "Folder.swift: [(Folder.kind,     Folder.pinnedOutputPort),":
            "a literal array of the two kinds a child can be",

        // ── accumulated into a dictionary or a set: the result is order-free ─────
        "ClangPreprocessor.swift: headerInputFiles":
            "the headers are materialised in the sandbox at their wire keys, which are unique paths; no header name reaches the command line",
        "SwiftFormulaConverter.swift: input.inputValues[Self.externalPackageJSONs] ?? [:]":
            "collects the manifests into a dictionary by package folder",
        "SwiftFormulaConverter.swift: input.inputValues[Self.targetFolders] ?? [:]":
            "collects the manifests into a dictionary by folder",
        "XcodeProjectConverter.swift: xcconfigValues":
            "collects the xcconfig texts into a dictionary by path",
        "ProjectBuilder.swift: inputs":
            "collects the decoded manifests into a dictionary by folder",
        "ProjectFinder.swift: allWatchedFolderManifests ?? [:]":
            "collects the manifests into an array whose only use is keyed by folder path, and the watched paths into a set",
        "ConfigFilter.swift: merged":
            "selects the qualified settings into a dictionary, rendered sorted",
        "ConfigurationText.swift: other":
            "merges one settings dictionary into another",
        "InfoPlistBuilder.swift: thisNode.properties":
            "each property is one plist entry under its own key, and a plist serialises its keys sorted",
        "LocalFileSystemTool.swift: environment":
            "lays the node's environment over the sandbox's, by name",
        "Node.swift: output.outputValues":
            "writes each value to the port it is keyed by",
        "Node.swift: output.inputWireSpecs":
            "applies each port's specs to that port, and applySpecs sorts the wires within it",
        "BuildEngine.swift: byNode":
            "collects each node's distinct messages into a set",
        "BuildEngine.swift: current":
            "collects the entries, which are reported sorted by label",
        "FormulaParser.swift: templateEnv":
            "each binding expands its own marker, and no two bindings share one",
        "TreeMerger.swift: merged.values":
            "a TreeManifest sorts its entries by path when it is built",
        "SwiftFormulaConverter.swift: specs.keys":
            "the missing paths are counted and reported sorted",
        "ToolRunner.swift: toolsByDescriptor.keys":
            "both readers impose an order: the error text sorts, and the tools reply sorts by version",

        // ── the order is imposed again further down ─────────────────────────────
        "XcodeProject.swift: objects":
            "appends the borrowed files, which each target sorts once every group is read",
        "GraphSpec.swift: otherPorts":
            "every port is compared; which mismatch is quoted first varies, the verdict does not",

        // ── a set of live objects, not a sequence anything is derived from ──────
        "ConnectionRegistry.swift: connections.values":
            "delivers to each connected client; they are independent of one another",
        "SocketConnection.swift: waiters.values":
            "fails each outstanding request; they are independent of one another",
    ]

    private static func swiftSources(under folder: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The dictionary view a line turns into a sequence — `specs.keys` of
    /// `specs.keys.filter { … }`, `merged.values` of `Array(merged.values)`. `first` is
    /// not among the consumers: it picks one element rather than ordering them.
    private static let viewRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.(?:keys|values))\s*(?:\)|\.(?:map|filter|compactMap|flatMap|joined|reduce)\b)"#)

    /// What `line` walks, or nil when it walks nothing: the subject of a
    /// `for (key, value) in …` loop, or the dictionary view it turns into a sequence.
    ///
    /// `continuation` is the line after, consulted only when the statement is plainly
    /// unfinished, so that a subject sorted on the next line is not read as unsorted.
    static func walkedText(inLine line: String, continuation: String) -> String? {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//") else { return nil }
        let statement = code.contains("{") ? code : code + " " + continuation.trimmingCharacters(in: .whitespaces)
        guard !statement.contains(".sorted") else { return nil }

        if code.contains("for ("), !code.contains(".enumerated()"), !code.contains("zip("),
           let inRange = code.range(of: ") in ") {
            var subject = String(code[inRange.upperBound...])
            if let whereRange = subject.range(of: " where ") {
                subject = String(subject[..<whereRange.lowerBound])
            }
            while subject.hasSuffix("{") || subject.hasSuffix(" ") {
                subject.removeLast()
            }
            return subject.isEmpty ? nil : subject
        }

        let range = NSRange(code.startIndex..., in: code)
        guard let match = viewRegex.firstMatch(in: code, range: range),
              let viewRange = Range(match.range(at: 1), in: code) else {
            return nil
        }
        let view = String(code[viewRange])
        // `Set(dict.keys)` asks what is in the dictionary, not in what order.
        return code.contains("Set(\(view))") ? nil : view
    }

    func test_everyWalkOfADictionaryIsSortedOrClassified() throws {
        var unclassified: [String] = []

        for folder in Self.scannedFolders {
            let url = Self.repositoryRoot.appendingPathComponent(folder, isDirectory: true)
            for file in try Self.swiftSources(under: url) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let continuation = index + 1 < lines.count ? lines[index + 1] : ""
                    guard let walked = Self.walkedText(inLine: line, continuation: continuation) else { continue }
                    guard Self.classifiedWalks["\(file.lastPathComponent): \(walked)"] == nil else { continue }
                    unclassified.append("\(folder)/\(file.lastPathComponent):\(index + 1): \(walked)")
                }
            }
        }

        XCTAssertTrue(unclassified.isEmpty, """
            These walk a dictionary in its own iteration order, which is seeded per process. \
            Sort the walk, or classify it in `classifiedWalks` with the reason its order \
            cannot reach a command line, a file, a formula, a cache key or a report:
            \(unclassified.joined(separator: "\n"))
            """)
    }

    /// The allowlist names walks that are still there; a sort or a deletion must not
    /// leave an entry behind for a later walk of the same text to inherit.
    func test_everyClassifiedWalkIsStillThere() throws {
        var found = Set<String>()

        for folder in Self.scannedFolders {
            let url = Self.repositoryRoot.appendingPathComponent(folder, isDirectory: true)
            for file in try Self.swiftSources(under: url) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let continuation = index + 1 < lines.count ? lines[index + 1] : ""
                    guard let walked = Self.walkedText(inLine: line, continuation: continuation) else { continue }
                    found.insert("\(file.lastPathComponent): \(walked)")
                }
            }
        }

        for key in Self.classifiedWalks.keys {
            XCTAssertTrue(found.contains(key), "classified walk no longer exists: \(key)")
        }
    }

    /// What the scan reads and what it passes over, stated on examples rather than left to
    /// the codebase to demonstrate.
    func test_theScanReadsTheShapesItClaimsTo() {
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings {", continuation: ""), "settings")
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings where key.isEmpty {", continuation: ""), "settings")
        XCTAssertEqual(Self.walkedText(inLine: "let names = Array(byName.keys)", continuation: ""), "byName.keys")
        XCTAssertEqual(Self.walkedText(inLine: "let all = table.values.map(\\.name)", continuation: ""), "table.values")

        XCTAssertNil(Self.walkedText(inLine: "for (key, value) in settings.sorted(by: { $0.key < $1.key }) {", continuation: ""))
        XCTAssertNil(Self.walkedText(inLine: "for (index, item) in items.enumerated() {", continuation: ""))
        XCTAssertNil(Self.walkedText(inLine: "// for (key, value) in settings {", continuation: ""))
        XCTAssertNil(Self.walkedText(inLine: "let one = table.values.first", continuation: ""))
        XCTAssertNil(Self.walkedText(inLine: "guard Set(specs.keys).isSubset(of: arrived) else {", continuation: ""))
        XCTAssertNil(Self.walkedText(inLine: "for (key, value) in settings", continuation: "    .sorted(by: { $0.key < $1.key }) {"))
    }
}
