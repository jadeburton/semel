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
/// A `Set` is seeded the same way, so turning one into a sequence is the same hazard
/// under another name: `Array(names)`, `.init(names)` where the annotation says array,
/// `for name in names`, `names.map { … }` are scanned for and classified alongside the
/// dictionary shapes, on the names each file declares as a set. `names.sorted()` states
/// its order and is not a hit.
///
/// Three order-dependent shapes are deliberately out of scope, because none of them is
/// about the order of a sequence: `dict.values.first` on a port the formula wires exactly
/// once, a dictionary gathered into a `Set` — a membership question — and an unstable
/// `sort` over keys that tie.
///
/// A sort is credited to a walk on two conditions, both of them about that walk rather
/// than about what is near it: the sort closes the expression the walk is in, and no
/// operator at the walk's own bracket depth stands between the two. So
/// `specs.keys.filter { … }.sorted()` is sorted and `byNode.map { key, value in key } +
/// extras.sorted()` is not — the `+` says the sort is of the other operand.
///
/// What the scan cannot see, for want of a rule that is exact rather than suggestive:
///
/// - a dictionary or a set passed to a function that walks it elsewhere. The walk is in
///   the callee, on a parameter whose declaration is the only thing that says where its
///   order came from, and no rule over single lines reaches it.
/// - a subject sorted further away than the scan reads. It reads the line, the line above
///   where the line begins with a `.` that runs on from it, and the line below where the
///   line carries no `{` to end the statement. A sort beyond that leaves a hit, to be
///   classified with the sort as its reason.
/// - a set that never says it is one. A name is a set here because a declaration in its
///   file says `Set`, so a set handed back by a function into an inferred binding reads
///   as an array — and, in the other direction, a name declared a set anywhere in a file
///   reads as a set throughout it, which costs a classification where the same name is an
///   array elsewhere in that file.
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
    /// Five kinds of entry are here: a walk of an array that merely looks like a walk of a
    /// dictionary, a walk that accumulates into a dictionary or a set (where only the
    /// result is kept, and it is the same result in any order), a walk whose order is
    /// imposed again further down, a walk over live connections, and a set turned into a
    /// sequence whose order nothing downstream can tell.
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
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: [(rootPackageFolder, rootManifest)] + availableManifests.sorted(by: { $0.key < $1.key })":
            "the root package's own pair, then the external manifests sorted by package folder; both halves state their order, and the sort is asked about because it belongs to the second of them",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: packages":
            "an array of pairs, the root package's and then the external ones sorted by folder, and the walk only fills a dictionary of demands, a set it sorts and a dictionary of locations",
        "SemelSwift/Sources/SemelSwift/SwiftPackageReader.swift: ancestors":
            "an array, built longest path first so the most specific prefix matches",
        "SemelApple/Sources/SemelApple/XcodeFormulaEmitter.swift: sourceFolders":
            "an array, in the order the project file lists the target's folders",
        "SemelCore/Sources/SemelCore/Nodes/ProjectFinder.swift: folderManifests":
            "an array of the decoded manifests",
        "semel-swift/Library/Preparation.swift: [(GeneratedFiles.formulaFileName, formula), (GeneratedFiles.configFileName, config)]":
            "a literal array of the two files to write",
        "SemelCore/Sources/SemelCore/Nodes/Folder.swift: [(Folder.kind,     Folder.pinnedOutputPort),":
            "a literal array of the two kinds a child can be",
        "SemelCore/Sources/SemelCore/Nodes/Folder.swift: [(Folder.kind,     Folder.contentRootOutputPort),":
            "a literal array of the two kinds a child can be, each with the port its content is on",

        // ── accumulated into a dictionary or a set: the result is order-free ─────
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: headerInputFiles":
            "the headers are materialised in the sandbox at their wire keys, which are unique paths; no header name reaches the command line",
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: inputs.includePathLists":
            "flattened into a set of include paths, which becomes wire-spec dictionaries and a count",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: input.inputValues[Self.externalPackageJSONs] ?? [:]":
            "collects the manifests into a dictionary by package folder",
        "SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift: input.inputValues[Self.targetFolders] ?? [:]":
            "collects the manifests into a dictionary by folder",
        "SemelCore/Sources/SemelCore/Nodes/ProjectBuilder.swift: inputs":
            "collects the decoded manifests into a dictionary by folder",
        "SemelCore/Sources/SemelCore/Nodes/ProjectFinder.swift: allWatchedFolderManifests ?? [:]":
            "collects the manifests into an array whose only use is keyed by folder path, and the watched paths into a set",
        "SemelCore/Sources/SemelCore/Nodes/ConfigFilter.swift: settings":
            "selects the qualified settings into a dictionary, rendered sorted",
        "SemelNodeKit/Sources/SemelNodeKit/ConfigurationText.swift: other":
            "merges one settings dictionary into another",
        "SemelApple/Sources/SemelApple/InfoPlistBuilder.swift: thisNode.properties":
            "each property is one plist entry under its own key, and a plist serialises its keys sorted",
        "SemelNodeKit/Sources/SemelNodeKit/LocalFileSystemTool.swift: environment":
            "lays the node's environment over the sandbox's, by name",
        "SemelCore/Sources/SemelCore/Node.swift: outputValues":
            "writes each value to the port it is keyed by",
        "SemelNodeKit/Sources/SemelNodeKit/TypeRegistry.swift: kindCache.values":
            "hands the registered types to a caller with a question to ask of each; the one caller collects the kinds that answer it into an `IN (…)` list, which has no order",
        "SemelCore/Sources/SemelCore/ErrorReport.swift: byNode.values":
            "flattens the ports back into one sequence, read port by port into a dictionary by node",
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
        "SemelNodeKit/Sources/SemelNodeKit/ToolRunner.swift: toolsByIdentity.values":
            "every reader imposes an order: the error text sorts, and both the tools reply and the written config sort by version",
        "SemelApple/Sources/SemelApple/XcodeBuildSettings.swift: values.values":
            "collects the names still referenced into a set, returned sorted",

        // ── the order is imposed again further down ─────────────────────────────
        "SemelApple/Sources/SemelApple/XcodeProject.swift: objects":
            "appends the borrowed files, which each target sorts once every group is read",
        "SemelSwift/Sources/SemelSwift/SwiftCompiler.swift: { fileName, nodeValue in":
            "the discovered and extra sources are sorted by path once the two halves are joined",
        "SemelSwift/Sources/SemelSwift/SwiftCompiler.swift: { wireKey, nodeValue in":
            "the module maps are sorted by path two lines below",

        // ── a set turned into a sequence: order-free at the far end ─────────────
        "SemelCore/Sources/SemelCore/ErrorReport.swift: Set(upstream)":
            "each failing source found is collected into a set of cause IDs",
        "SemelCore/Sources/SemelCore/ErrorReport.swift: carriers":
            "each carrier adds one to its cause's count, which comes to the same count whichever carrier is counted first; the entries are sorted before they are returned",
        "SemelCore/Sources/SemelCore/Nodes/ProjectFinder.swift: watchedPaths":
            "gives each watched folder its own wire spec, in a dictionary keyed by that folder's path",
        "SemelSwift/Sources/SemelSwift/SwiftSDKFingerprint.swift: keys":
            "the resource values to fetch with each file, an argument that asks for them rather than ordering anything; the fingerprint's own lines are sorted before they are hashed",
        "SemelClang/Sources/SemelClang/ClangPreprocessor.swift: setOfIncludeFiles":
            "becomes wire-spec dictionaries keyed by include path, and a count of them",

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

    /// A name declared as a `Set`: `let names: Set<String> = []`, the parameter of
    /// `func f(paths: Set<String>)` or of `f(into set: inout Set<String>)`. Group 1 is
    /// the name.
    private static let setDeclarationRegex = try! NSRegularExpression(
        pattern: #"(?:let\s+|var\s+|[(,]\s*|^\s*)(?:[A-Za-z_][A-Za-z0-9_]*\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:inout\s+)?Set<"#)

    /// A name bound to a set: `var visited = Set<ObjectID>()`, `let arrived = Set(keys)`.
    /// Group 1 is the name.
    private static let setBindingRegex = try! NSRegularExpression(
        pattern: #"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?=\s*Set[(<]"#)

    /// A set handed to an initialiser that keeps an order — `Array(names)`, or
    /// `.init(names)` where the annotation says array. Group 1 is the set.
    private static let setInitialiserRegex = try! NSRegularExpression(
        pattern: #"(?:Array|\.init)\(\s*(Set\([^()]*\)|[A-Za-z_][A-Za-z0-9_]*)\s*\)"#)

    /// A set walked as a sequence — `names.map { … }`, `Set(paths).joined()`. Group 1 is
    /// the set. `sorted` is not among the consumers: it states its order.
    private static let setSequenceRegex = try! NSRegularExpression(
        pattern: #"(Set\([^()]*\)|[A-Za-z_][A-Za-z0-9_]*)\.(?:map|filter|compactMap|flatMap|joined|reduce|forEach)\b"#)

    /// A `.sorted` applied to what the text before it produced, across any brackets the
    /// conversion closes: the `.sorted()` of `Array(Set(folders)).sorted()`.
    private static let sortedResultRegex = try! NSRegularExpression(
        pattern: #"^[)\]\s]*\.sorted\b"#)

    /// The names `lines` declare as a `Set`. A file's own declarations are what tells a
    /// walk of a set from a walk of an array.
    static func setNames(inLines lines: [String]) -> Set<String> {
        var names: Set<String> = []
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            for regex in [setDeclarationRegex, setBindingRegex] {
                for match in regex.matches(in: line, range: range) {
                    guard let nameRange = Range(match.range(at: 1), in: line) else { continue }
                    names.insert(String(line[nameRange]))
                }
            }
        }
        return names
    }

    /// Whether `text` names a set: one the file declares, or a `Set(…)` written in place.
    private static func isSet(_ text: String, setNames: Set<String>) -> Bool {
        setNames.contains(text) || text.hasPrefix("Set(")
    }

    /// Whether `expression`, read from the walk it begins with, states the order it hands
    /// on — sorted, enumerated or zipped. Two things have to hold, and together they are
    /// what "the sort is a sort of this walk" means at the level of text:
    ///
    /// - the sort closes the expression, so nothing is applied to the sorted sequence
    ///   afterwards and the sort is not nested in a call whose result travels on;
    /// - nothing between the walk and the sort is an operator at the walk's own bracket
    ///   depth. `byNode.map { key, value in key } + extras.sorted()` sorts `extras`, and
    ///   the `+` is how that is known.
    static func isOrdered(_ expression: String) -> Bool {
        var text = expression.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("{") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return false }

        for keyword in [".sorted", ".enumerated", "zip"] {
            var searchStart = text.startIndex
            while let found = text.range(of: keyword, range: searchStart..<text.endIndex) {
                if !carriesAnOperator(text[..<found.lowerBound]),
                   closesTheExpression(text[found.upperBound...]) {
                    return true
                }
                searchStart = found.upperBound
            }
        }
        return false
    }

    /// Whether `statement` sorts the walk `locator` names, `locator` being the walked text
    /// as the line spells it. The statement is read from where the walk starts, so a sort
    /// of something earlier in the line is not read as sorting the walk.
    private static func statementSorts(_ locator: String, in statement: String) -> Bool {
        guard let walk = statement.range(of: locator) else { return false }
        return isOrdered(String(statement[walk.lowerBound...]))
    }

    /// Whether `between` carries an operator at the depth the walk sits at — a `+`, a
    /// comma, a comparison — which puts what follows it in a different operand from the
    /// walk, so that a sort beyond it sorts something else.
    ///
    /// Three kinds of punctuation are not among them, none of which parts an expression
    /// from its own sort: `=` and `:`, which separate a walk from its name or its type,
    /// and the postfix `!` and `?` of `values[port]!.sorted()`, which stay in the chain.
    private static func carriesAnOperator(_ between: Substring) -> Bool {
        var depth = 0
        for character in literalsCollapsed(between) {
            switch character {
            case "(", "{", "[":
                depth += 1
            case ")", "}", "]":
                depth -= 1
            default:
                if depth <= 0, "+-*/%,;<>&|^~".contains(character) { return true }
            }
        }
        return false
    }

    /// `text` with each string literal collapsed to a single `_`, so that a bracket or an
    /// operator written inside one counts as neither structure nor separator — the `(` of
    /// `byNode.map { key, value in "(" } + extras.sorted()` leaves the `+` where the scan
    /// can see it — while the literal still counts as something standing there. Both the
    /// plain form, where a `\"` does not end the literal, and the raw form `#"…"#`, which
    /// ends only at `"#`, are read.
    private static func literalsCollapsed(_ text: Substring) -> String {
        var collapsed = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index...].hasPrefix("#\"") {
                var scan = text.index(index, offsetBy: 2)
                while scan < text.endIndex, !text[scan...].hasPrefix("\"#") {
                    scan = text.index(after: scan)
                }
                index = scan < text.endIndex ? text.index(scan, offsetBy: 2) : text.endIndex
                collapsed.append("_")
            } else if text[index] == "\"" {
                var scan = text.index(after: index)
                while scan < text.endIndex, text[scan] != "\"" {
                    if text[scan] == "\\", text.index(after: scan) < text.endIndex {
                        scan = text.index(after: scan)
                    }
                    scan = text.index(after: scan)
                }
                index = scan < text.endIndex ? text.index(after: scan) : text.endIndex
                collapsed.append("_")
            } else {
                collapsed.append(text[index])
                index = text.index(after: index)
            }
        }

        return collapsed
    }

    /// Whether `tail` is all that is left of an expression once its sort is named: the
    /// sort's own arguments or closure and nothing else. A bracket `tail` closes but did
    /// not open belongs to something the sort is nested in, and anything at all after the
    /// call is applied to the sorted sequence rather than being it. Brackets inside a
    /// string literal are text, and are collapsed away before the depth is read.
    private static func closesTheExpression(_ tail: Substring) -> Bool {
        var depth = 0
        for character in literalsCollapsed(tail) {
            switch character {
            case "(", "{", "[":
                depth += 1
            case ")", "}", "]":
                depth -= 1
                if depth < 0 { return false }
            default:
                if depth == 0, !character.isWhitespace { return false }
            }
        }
        return depth == 0
    }

    /// The set `code` turns into a sequence, or nil: `Array(names)`, `names.flatMap { … }`
    /// — a `for` loop over one is read where the other `for` shapes are. A conversion the
    /// same expression sorts on the spot, `Array(Set(folders)).sorted()`, is not one.
    private static func convertedSet(inCode code: String, setNames: Set<String>) -> String? {
        let range = NSRange(code.startIndex..., in: code)
        for regex in [setInitialiserRegex, setSequenceRegex] {
            for match in regex.matches(in: code, range: range) {
                guard let subjectRange = Range(match.range(at: 1), in: code),
                      let matchRange = Range(match.range, in: code) else { continue }
                let subject = String(code[subjectRange])
                guard isSet(subject, setNames: setNames) else { continue }
                let tail = String(code[matchRange.upperBound...])
                guard sortedResultRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) == nil else {
                    continue
                }
                return subject
            }
        }
        return nil
    }

    /// What `line` walks, or nil when it walks nothing: the subject of a `for` loop that
    /// binds a pair, names `keys` or `values` or is a set; the dictionary view or set the
    /// line turns into a sequence; or the receiver of a call whose closure takes two
    /// bindings.
    ///
    /// `previous` and `continuation` are its neighbours, consulted only where the
    /// statement plainly runs into them, so that a sort one line above or below is not
    /// read as absent. Wherever a sort is read, it has to be the walked subject that it
    /// sorts.
    ///
    /// `setNames` are the names the file declares as a `Set`.
    static func walkedText(inLine line: String,
                           previous: String = "",
                           continuation: String = "",
                           setNames: Set<String> = []) -> String? {
        let code = line.trimmingCharacters(in: .whitespaces)
        guard !code.hasPrefix("//"), !code.hasPrefix("///") else { return nil }

        // The line below, where the statement runs into it.
        let continued = code.contains("{") ? "" : " " + continuation.trimmingCharacters(in: .whitespaces)
        var statement = code
        if code.hasPrefix(".") {
            statement = previous.trimmingCharacters(in: .whitespaces) + " " + statement
        }
        statement += continued

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
            guard !subject.isEmpty, !isOrdered(subject + continued) else { return nil }
            let walksAPair = binding.contains(",")
            let walksAView = subject.hasSuffix(".keys") || subject.hasSuffix(".values")
            return walksAPair || walksAView || isSet(subject, setNames: setNames) ? subject : nil
        }

        let range = NSRange(code.startIndex..., in: code)
        if let match = viewRegex.firstMatch(in: code, range: range),
           let viewRange = Range(match.range(at: 1), in: code) {
            let view = String(code[viewRange])
            // `Set(dict.keys)` asks what is in the dictionary, not in what order.
            return code.contains("Set(\(view))") || statementSorts(view, in: statement) ? nil : view
        }

        if let convertedSet = convertedSet(inCode: code, setNames: setNames),
           !statementSorts(convertedSet, in: statement) {
            return convertedSet
        }

        guard let match = pairClosureRegex.firstMatch(in: code, range: range),
              let bindingRange = Range(match.range(at: 2), in: code),
              let callRange = Range(match.range, in: code) else {
            return nil
        }
        // The receiver when the line carries it; the bindings when the call is a
        // continuation of the line above, which is as much as the line itself says —
        // and in that case the receiver is what that line's expression ends with.
        if let receiverRange = Range(match.range(at: 1), in: code) {
            let receiver = String(code[receiverRange])
            return statementSorts(receiver, in: statement) ? nil : receiver
        }
        let call = String(code[callRange])
        if let callInStatement = statement.range(of: call),
           isOrdered(String(statement[..<callInStatement.lowerBound])) || statementSorts(call, in: statement) {
            return nil
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
                let sets = setNames(inLines: lines)
                for (index, line) in lines.enumerated() {
                    guard let walked = walkedText(inLine: line,
                                                  previous: index > 0 ? lines[index - 1] : "",
                                                  continuation: index + 1 < lines.count ? lines[index + 1] : "",
                                                  setNames: sets) else {
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

    /// A neighbouring `.sorted` covers the walk only where it is the walked subject that
    /// it sorts: a sort of something else on the line above or below leaves the walk in
    /// the dictionary's own order, and the scan says so.
    func test_theScanReadsOnlyASortOfTheWalkedSubject() {
        XCTAssertEqual(Self.walkedText(inLine: "let entries = byNode.map { nodeID, ports in ports.sorted() }"),
                       "byNode")
        XCTAssertEqual(Self.walkedText(inLine: ".map { key, value in one(key, value) }",
                                       previous: "let files = merge(table, extras.sorted())"), "{ key, value in")
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings",
                                       continuation: "    .filter { $0.value.isEmpty } {"), "settings")
        XCTAssertEqual(Self.walkedText(inLine: "for (key, value) in settings where ordered.sorted().isEmpty {"),
                       "settings")

        // A sort that ends the statement but belongs to the other side of an operator is
        // a sort of that other operand, and the walk is still a walk.
        XCTAssertEqual(Self.walkedText(inLine: "let names = byNode.map { key, value in key } + extras.sorted()"),
                       "byNode")
        XCTAssertEqual(Self.walkedText(inLine: "let all = specs.keys.map { one($0) } + extras.sorted()"),
                       "specs.keys")
        XCTAssertEqual(Self.walkedText(inLine: "let lines = visited.map { $0.name } + extras.sorted()",
                                       setNames: ["visited"]), "visited")

        // A bracket inside a string literal is text, not structure: counting it would
        // leave the `+` below at a depth the scan does not read, and the walk would pass
        // as sorted by a sort of `extras`.
        XCTAssertEqual(Self.walkedText(inLine: #"let names = byNode.map { key, value in "(" } + extras.sorted()"#),
                       "byNode")
        XCTAssertNil(Self.walkedText(inLine: #"let names = byNode.map { key, value in key }.sorted { $0 + ")" < $1 }"#))

        // The converse: a sort the statement ends in does sort what it walked, however
        // many steps the walk took to reach it.
        XCTAssertNil(Self.walkedText(inLine: "let missing = specs.keys.filter { absent($0) }.sorted()"))
        XCTAssertNil(Self.walkedText(inLine: "let entries = byNode.map { nodeID, ports in one(nodeID, ports) }.sorted()"))
        XCTAssertNil(Self.walkedText(inLine: "let ordered = visited.map { $0.name }.sorted()", setNames: ["visited"]))
        XCTAssertNil(Self.walkedText(inLine: "let pairs = zip(keys, values).map { key, value in one(key, value) }"))
    }

    /// The set shapes, on examples: a set is seeded per process exactly as a dictionary
    /// is, and a conversion of one into a sequence hands that seed on.
    func test_theScanReadsSetConversions() {
        let names: Set<String> = ["visited"]

        XCTAssertEqual(Self.walkedText(inLine: "let ordered = Array(visited)", setNames: names), "visited")
        XCTAssertEqual(Self.walkedText(inLine: "let ordered: [String] = .init(visited)", setNames: names), "visited")
        XCTAssertEqual(Self.walkedText(inLine: "for path in visited {", setNames: names), "visited")
        XCTAssertEqual(Self.walkedText(inLine: "let lines = visited.map { $0.name }", setNames: names), "visited")
        XCTAssertEqual(Self.walkedText(inLine: #"let text = Set(paths).joined(separator: " ")"#, setNames: names),
                       "Set(paths)")

        XCTAssertNil(Self.walkedText(inLine: "let ordered = visited.sorted()", setNames: names))
        XCTAssertNil(Self.walkedText(inLine: "let ordered = Array(Set(paths)).sorted().map { $0.name }",
                                     setNames: names))
        XCTAssertNil(Self.walkedText(inLine: "guard visited.contains(path) else {", setNames: names))
        XCTAssertNil(Self.walkedText(inLine: "visited.insert(path)", setNames: names))
        XCTAssertNil(Self.walkedText(inLine: "for path in ordered {", setNames: names))
        XCTAssertNil(Self.walkedText(inLine: "let lines = ordered.map { $0.name }", setNames: names))
    }

    /// Which declarations make a name a set, since that is what the set shapes are read
    /// against.
    func test_theScanFindsTheSetsAFileDeclares() {
        let declared = Self.setNames(inLines: [
            "        var visited = Set<ObjectID>()",
            #"    let excluded: Set<String> = ["a"]"#,
            "    static func reconcile(existing: Set<String>, into set: inout Set<String>) {",
            "        let arrived = Set(manifests.map(\\.key))",
            "        var names: [String] = []",
            "        var byNode: [ObjectID: Set<String>] = [:]",
        ])

        XCTAssertEqual(declared, ["visited", "excluded", "existing", "set", "arrived"])
    }
}
