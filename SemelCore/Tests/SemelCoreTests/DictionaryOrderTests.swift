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
/// blanket ban would be noise. This is the middle course: a scan for the shapes that turn
/// a dictionary into a sequence, with every existing one classified. A hit that is not in
/// the allowlist is a walk nobody has classified yet — sort it, or add it here with the
/// reason its order cannot escape.
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

    /// Every non-test source a build runs through: each package's `Sources`, the root
    /// package's library targets, and the three executables' `main.swift`, which are
    /// targets of one file. A path here is a folder to walk or a single file.
    private static let scannedPaths = [
        "SemelNodeKit/Sources", "SemelDatabaseModels/Sources", "SemelCore/Sources",
        "SemelSwift/Sources", "SemelClang/Sources", "SemelApple/Sources",
        "SemelProtocol/Sources", "SemelExamples/Sources",
        "semel/CommandInterpreter", "semel/Server", "semel/Transport", "semel-swift/Library",
        "semel/main.swift", "semel-server/main.swift", "semel-swift/main.swift",
    ]

    /// The walks that need no sort, each with why its order cannot reach anything a build
    /// produces. Keyed by the file's path from the repository root and the text walked
    /// rather than by line, so a walk that moves keeps its entry, a walk in another file
    /// of the same name cannot borrow it, and a new walk earns its own.
    ///
    /// Four kinds of entry are here: a walk of an array that merely looks like a walk of a
    /// dictionary, a walk that accumulates into a dictionary or a set (where only the
    /// result is kept, and it is the same result in any order), a walk whose order is
    /// imposed again further down, and a walk over live connections.
    private static let classifiedWalks: [String: String] = [
        // ── arrays of pairs: ordered already, by whoever built them ──────────────
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: inputs.headerFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SemelSwift/Sources/SemelSwift/SwiftCompiler.swift: moduleMapFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SemelSwift/Sources/SemelSwift/SwiftLinker.swift: libraryFolderManifests":
            "an array, sorted by wire key where it is decoded",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: externalPackages":
            "an array, sorted by package folder so a name conflict resolves the same way twice",
        "SemelSwift/Sources/SemelSwift/SwiftPackageReader.swift: ancestors":
            "an array, built longest path first so the most specific prefix matches",
        "SemelApple/Sources/SemelApple/XcodeFormulaEmitter.swift: sourceFolders":
            "an array, in the order the project file lists the target's folders",
        "SemelCore/Sources/SemelCore/Nodes/ProjectFinder.swift: folderManifests":
            "an array of the decoded manifests",
        "semel-swift/Library/GeneratedFiles.swift: platformSettings(toolName: entry.toolName, platform: platform,":
            "an array of pairs the function returns in the order it states them",
        "semel-swift/Library/Preparation.swift: [(GeneratedFiles.formulaFileName, formula), (GeneratedFiles.configFileName, config)]":
            "a literal array of the two files to write",
        "SemelCore/Sources/SemelCore/Nodes/Folder.swift: [(Folder.kind,     Folder.pinnedOutputPort),":
            "a literal array of the two kinds a child can be",

        // ── accumulated into a dictionary or a set: the result is order-free ─────
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: headerInputFiles":
            "the headers are materialised in the sandbox at their wire keys, which are unique paths; no header name reaches the command line",
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: inputs.includePathLists":
            "flattened into a set of include paths, which becomes wire-spec dictionaries and a count",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: input.inputValues[Self.externalPackageJSONs] ?? [:]":
            "collects the manifests into a dictionary by package folder",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: input.inputValues[Self.targetFolders] ?? [:]":
            "collects the manifests into a dictionary by folder",
        "SemelApple/Sources/SemelApple/XcodeProjectConverter.swift: xcconfigValues":
            "collects the xcconfig texts into a dictionary by path",
        "SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift: inputs":
            "collects the decoded manifests into a dictionary by folder",
        "SemelCore/Sources/SemelCore/Nodes/ProjectFinder.swift: allWatchedFolderManifests ?? [:]":
            "collects the manifests into an array whose only use is keyed by folder path, and the watched paths into a set",
        "SemelCore/Sources/SemelCore/Nodes/ConfigFilter.swift: merged":
            "selects the qualified settings into a dictionary, rendered sorted",
        "SemelNodeKit/Sources/SemelNodeKit/ConfigurationText.swift: other":
            "merges one settings dictionary into another",
        "SemelApple/Sources/SemelApple/InfoPlistBuilder.swift: thisNode.properties":
            "each property is one plist entry under its own key, and a plist serialises its keys sorted",
        "SemelNodeKit/Sources/SemelNodeKit/LocalFileSystemTool.swift: environment":
            "lays the node's environment over the sandbox's, by name",
        "SemelCore/Sources/SemelCore/Node.swift: output.outputValues":
            "writes each value to the port it is keyed by",
        "SemelCore/Sources/SemelCore/Node.swift: output.inputWireSpecs":
            "applies each port's specs to that port, and applySpecs sorts the wires within it",
        "SemelCore/Sources/SemelCore/BuildEngine.swift: byNode":
            "collects each node's distinct messages into a set",
        "SemelCore/Sources/SemelCore/BuildEngine.swift: current":
            "carries each node's remembered messages forward, node by node",
        "SemelCore/Sources/SemelCore/ErrorReport.swift: byNode":
            "collects each node's distinct messages into a set",
        "SemelCore/Sources/SemelCore/ErrorReport.swift: reporting.keys":
            "starts a count per cause; the entries are sorted by label and then by node",
        "SemelCore/Sources/SemelCore/ErrorReport.swift: counts":
            "builds one entry per cause, and the entries are sorted before they are returned",
        "SemelCore/Sources/SemelCore/FormulaParser.swift: templateEnv":
            "each binding expands its own marker, and no two bindings share one",
        "SemelCore/Sources/SemelCore/Nodes/TreeMerger.swift: merged.values":
            "a TreeManifest sorts its entries by path when it is built",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: specs.keys":
            "the missing paths are counted and reported sorted",
        "SemelNodeKit/Sources/SemelNodeKit/ToolRunner.swift: toolsByDescriptor.keys":
            "every reader imposes an order: the error text sorts, and both the tools reply and the written config sort by version",
        "SemelApple/Sources/SemelApple/XcodeBuildSettings.swift: values.values":
            "collects the names still referenced into a set, returned sorted",

        // ── the order is imposed again further down ─────────────────────────────
        "SemelApple/Sources/SemelApple/XcodeProject.swift: objects":
            "appends the borrowed files, which each target sorts once every group is read",
        "SemelCore/Sources/SemelCore/GraphSpec.swift: otherPorts":
            "every port is compared; which mismatch is quoted first varies, the verdict does not",
        "SemelSwift/Sources/SemelSwift/SwiftCompiler.swift: { fileName, nodeValue in":
            "the discovered and extra sources are sorted by path once the two halves are joined",
        "SemelSwift/Sources/SemelSwift/SwiftCompiler.swift: { wireKey, nodeValue in":
            "the module maps are sorted by path two lines below",

        // ── a set of live objects, not a sequence anything is derived from ──────
        "semel/Server/ConnectionRegistry.swift: connections.values":
            "delivers to each connected client; they are independent of one another",
        "semel/CommandInterpreter/SocketConnection.swift: waiters.values":
            "fails each outstanding request; they are independent of one another",
    ]

    /// The Swift files at `path`, which is a folder to walk or a single file. Sorted, so a
    /// failure lists its hits the same way twice.
    private static func swiftSources(at path: URL) throws -> [URL] {
        if path.pathExtension == "swift" {
            return FileManager.default.fileExists(atPath: path.path) ? [path] : []
        }
        guard let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// The dictionary view a line turns into a sequence — `specs.keys` of
    /// `specs.keys.filter { … }`, `merged.values` of `Array(merged.values)`. `first` is
    /// not among the consumers: it picks one element rather than ordering them.
    private static let viewRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\.(?:keys|values))\s*(?:\)|\.(?:map|filter|compactMap|flatMap|joined|reduce)\b)"#)

    /// A call whose closure takes two bindings — `byNode.map { nodeID, ports in … }` — which
    /// is how a dictionary is walked without naming `keys` or `values` at all. Group 1 is
    /// the receiver when the line carries it, group 2 the bindings.
    private static let pairClosureRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)?\.(?:map|compactMap|flatMap|forEach|filter|reduce)\s*\{\s*\(?\s*([A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*)\s*\)?\s+in\b"#)

    /// What `line` walks, or nil when it walks nothing: the subject of a `for` loop that
    /// binds a pair or names `keys` or `values`, the dictionary view it turns into a
    /// sequence, or the receiver of a call whose closure takes two bindings.
    ///
    /// `previous` and `continuation` are its neighbours, consulted only where the
    /// statement plainly runs into them, so that a sort one line above or below is not
    /// read as absent.
    static func walkedText(inLine line: String, previous: String = "", continuation: String = "") -> String? {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//"), !code.hasPrefix("///") else { return nil }

        var statement = code
        if code.hasPrefix(".") {
            statement = previous.trimmingCharacters(in: .whitespaces) + " " + statement
        }
        if !code.contains("{") {
            statement += " " + continuation.trimmingCharacters(in: .whitespaces)
        }
        // An enumerated or zipped sequence is ordered by construction, and a sorted one
        // says so on the spot.
        guard !statement.contains(".sorted"), !statement.contains(".enumerated()"),
              !statement.contains("zip(") else {
            return nil
        }

        // `for case .remote(_, let url) in …` matches a pattern; it does not bind a pair.
        if code.hasPrefix("for "), !code.hasPrefix("for case "), let inRange = code.range(of: " in ") {
            let binding = String(code[code.index(code.startIndex, offsetBy: 4)..<inRange.lowerBound])
            var subject = String(code[inRange.upperBound...])
            if let whereRange = subject.range(of: " where ") {
                subject = String(subject[..<whereRange.lowerBound])
            }
            while subject.hasSuffix("{") || subject.hasSuffix(" ") {
                subject.removeLast()
            }
            let walksAPair = binding.contains(",")
            let walksAView = subject.hasSuffix(".keys") || subject.hasSuffix(".values")
            return (walksAPair || walksAView) && !subject.isEmpty ? subject : nil
        }

        let range = NSRange(code.startIndex..., in: code)
        if let match = viewRegex.firstMatch(in: code, range: range),
           let viewRange = Range(match.range(at: 1), in: code) {
            let view = String(code[viewRange])
            // `Set(dict.keys)` asks what is in the dictionary, not in what order.
            return code.contains("Set(\(view))") ? nil : view
        }

        guard let match = pairClosureRegex.firstMatch(in: code, range: range),
              let bindingRange = Range(match.range(at: 2), in: code) else {
            return nil
        }
        // The receiver when the line carries it; the bindings when the call is a
        // continuation of the line above, which is as much as the line itself says.
        if let receiverRange = Range(match.range(at: 1), in: code) {
            return String(code[receiverRange])
        }
        return "{ \(code[bindingRange]) in"
    }

    /// Every walk the scan finds, as `<path from the root>: <text walked>`, with the line
    /// it is on.
    private static func walks() throws -> [(key: String, location: String)] {
        var found: [(key: String, location: String)] = []

        for path in scannedPaths {
            let url = repositoryRoot.appendingPathComponent(path)
            let sources = try swiftSources(at: url)
            XCTAssertFalse(sources.isEmpty, "no Swift file under '\(path)': the scan covers nothing there")

            for file in sources {
                let relativePath = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    guard let walked = walkedText(inLine: line,
                                                  previous: index > 0 ? lines[index - 1] : "",
                                                  continuation: index + 1 < lines.count ? lines[index + 1] : "") else {
                        continue
                    }
                    found.append((key: "\(relativePath): \(walked)", location: "\(relativePath):\(index + 1)"))
                }
            }
        }

        return found
    }

    func test_everyWalkOfADictionaryIsSortedOrClassified() throws {
        let unclassified = try Self.walks()
            .filter { Self.classifiedWalks[$0.key] == nil }
            .map { "\($0.location): \($0.key.components(separatedBy: ": ").last ?? "")" }

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
        let found = Set(try Self.walks().map(\.key))

        for key in Self.classifiedWalks.keys.sorted() {
            XCTAssertTrue(found.contains(key), "classified walk is not in the sources: \(key)")
        }
    }

    /// What the scan reads and what it passes over, stated on examples rather than left to
    /// the codebase to demonstrate.
    func test_theScanReadsTheShapesItClaimsTo() {
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings {"), "settings")
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings where key.isEmpty {"), "settings")
        XCTAssertEqual(Self.walkedText(inLine: "for value in table.values where value.isEmpty {"), "table.values")
        XCTAssertEqual(Self.walkedText(inLine: "for key in table.keys {"), "table.keys")
        XCTAssertEqual(Self.walkedText(inLine: "let names = Array(byName.keys)"), "byName.keys")
        XCTAssertEqual(Self.walkedText(inLine: "let all = table.values.map(\\.name)"), "table.values")
        XCTAssertEqual(Self.walkedText(inLine: "let entries = byNode.map { nodeID, ports in"), "byNode")
        XCTAssertEqual(Self.walkedText(inLine: ".map { key, value in one(key, value) }",
                                       previous: "let files = table"), "{ key, value in")

        XCTAssertNil(Self.walkedText(inLine: "for (key, value) in settings.sorted(by: { $0.key < $1.key }) {"))
        XCTAssertNil(Self.walkedText(inLine: "for (index, item) in items.enumerated() {"))
        XCTAssertNil(Self.walkedText(inLine: "for case .remote(_, let url) in targets.flatMap(\\.products) {"))
        XCTAssertNil(Self.walkedText(inLine: "for item in items {"))
        XCTAssertNil(Self.walkedText(inLine: "// for (key, value) in settings {"))
        XCTAssertNil(Self.walkedText(inLine: "let one = table.values.first"))
        XCTAssertNil(Self.walkedText(inLine: "guard Set(specs.keys).isSubset(of: arrived) else {"))
        XCTAssertNil(Self.walkedText(inLine: "for (key, value) in settings",
                                     continuation: "    .sorted(by: { $0.key < $1.key }) {"))
        XCTAssertNil(Self.walkedText(inLine: ".map { key, value in one(key, value) }",
                                     previous: "let files = table.sorted { $0.key < $1.key }"))
    }
}
