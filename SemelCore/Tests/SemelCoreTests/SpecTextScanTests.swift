//
//  SpecTextScanTests.swift
//  SemelCore
//
//  B-115. Text is for what a person writes or reads; between components there are trees.
//  A spec assembled as a string in the sources, or parsed back anywhere but the formula
//  parser, is a component handing another one text to parse — the shape this repository
//  gave up. Scanned like the dictionary-order and hermeticity rules, because it is the
//  same kind of rule: one that compiles fine when broken.
//

import Foundation
import XCTest

final class SpecTextScanTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every folder holding sources a running Semel is built from. Tests are not scanned:
    /// a spec literal in a test fixture is text a person wrote for that test.
    private static let sourceFolders = [
        "SemelNodeKit/Sources", "SemelDatabaseModels/Sources", "SemelCore/Sources", "SemelClang/Sources",
        "SemelSwift/Sources", "SemelApple/Sources", "SemelExamples/Sources",
        "semel/Server", "semel/CommandInterpreter", "semel/Transport", "semel-swift",
    ]

    /// Files that write spec text on purpose, and why: each writes a *formula* — text a
    /// person reads, includes or edits — never a demand another component parses.
    private static let filesThatWriteFormulas: [String: String] = [
        "FormulaParser.swift":        "the one parser; `import(path:)` reads a spec a person wrote into a file",
        "GraphSpec.swift":            "the parser's definition",
        "ClangPrelude.swift":         "a prelude is formula text",
        "SwiftPrelude.swift":         "a prelude is formula text",
        "ApplePrelude.swift":         "a prelude is formula text",
        "SwiftFormulaConverter.swift": "emits a package's formula",
        "XcodeFormulaEmitter.swift":  "emits a project's formula",
        "GeneratedFiles.swift":       "prepare writes a project's formula",
    ]

    /// A type call with a quoted value inside and a port suffix after, inside a string
    /// literal: `"…Type(key: '…').port…"`. The quote is what tells a spec from an
    /// interpolated call such as `\(UUID().uuidString)`.
    private static let specInAStringPattern =
        #""[^"\n]*\b[A-Z][A-Za-z0-9]*\([^"\n]*'[^"\n]*\)\.[a-z][A-Za-z]*\b[^"\n]*""#

    private static func swiftSources() throws -> [URL] {
        var files: [URL] = []
        for folder in sourceFolders {
            let url = repositoryRoot.appendingPathComponent(folder, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                continue
            }
            files += enumerator.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" && !$0.path.contains("/Tests/") && !$0.path.contains("TestSupport") }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func offendingLines(in file: URL, where offends: (String) -> Bool) throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.components(separatedBy: "\n").enumerated().compactMap { number, line in
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), offends(code) else {
                return nil
            }
            return "\(file.path.dropFirst(repositoryRoot.path.count + 1)):\(number + 1): \(code)"
        }
    }

    func test_noComponentHandsAnotherASpecAsAString() throws {
        let specInAString = try NSRegularExpression(pattern: Self.specInAStringPattern)
        var offenders: [String] = []
        for file in try Self.swiftSources() where Self.filesThatWriteFormulas[file.lastPathComponent] == nil {
            offenders += try Self.offendingLines(in: file) { code in
                specInAString.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These assemble a spec as text for another component to parse. Build a tree — \
            `GraphSpecNode(Type.self, …)`, `.staticFile(at:)`, `.folderManifest(at:)` — or, for a file \
            that writes a formula, name it in `filesThatWriteFormulas` with the reason:
            \(offenders.joined(separator: "\n"))
            """)
    }

    func test_onlyTheFormulaParserParsesSpecText() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources() where !["FormulaParser.swift", "GraphSpec.swift"].contains(file.lastPathComponent) {
            offenders += try Self.offendingLines(in: file) { $0.contains("GraphSpecNode.parse(") }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These parse spec text. A tree that reaches a component should arrive as a tree:
            \(offenders.joined(separator: "\n"))
            """)
    }

    func test_everyFileAllowedToWriteFormulasExists() throws {
        let names = Set(try Self.swiftSources().map(\.lastPathComponent))
        for name in Self.filesThatWriteFormulas.keys.sorted() {
            XCTAssertTrue(names.contains(name), "allowlisted file no longer exists: \(name)")
        }
    }
}
