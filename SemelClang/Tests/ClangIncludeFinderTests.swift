@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangIncludeFinderTests: SemelClangTestCase {

    // MARK: - Basic extraction

    func test_extractsQuotedInclude() {
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: #"#include "hello.h""#)
        XCTAssertEqual(result, ["hello.h"])
    }

    func test_ignoresAngleBracketInclude() {
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: "#include <stdio.h>")
        XCTAssertTrue(result.isEmpty)
    }

    func test_extractsMultipleIncludes() {
        let source = """
            #include "a.h"
            #include "b.h"
            #include "c.h"
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["a.h", "b.h", "c.h"])
    }

    func test_mixedQuotedAndAngleBracket_returnsOnlyQuoted() {
        let source = """
            #include <stdio.h>
            #include "local.h"
            #include <stdlib.h>
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["local.h"])
    }

    // MARK: - Deduplication

    func test_deduplicatesRepeatedIncludes() {
        let source = """
            #include "hello.h"
            #include "hello.h"
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, "hello.h")
    }

    func test_deduplication_preservesFirstOccurrenceOrder() {
        let source = """
            #include "b.h"
            #include "a.h"
            #include "b.h"
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["b.h", "a.h"])
    }

    // MARK: - Comment stripping

    func test_includeInLineComment_isIgnored() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: #"// #include "hidden.h""#
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_includeInBlockComment_isIgnored() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: #"/* #include "hidden.h" */"#
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_includeAfterLineComment_isCaptured() {
        let source = """
            // this is a comment
            #include "real.h"
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["real.h"])
    }

    func test_multilineBlockComment_includeInsideIsIgnored() {
        let source = """
            /*
             * #include "inside_comment.h"
             */
            #include "outside.h"
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["outside.h"])
    }

    // MARK: - Whitespace variants

    func test_includeWithTabIndent() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: "\t#include \"indented.h\""
        )
        XCTAssertEqual(result, ["indented.h"])
    }

    func test_includeWithSpacesBetweenHashAndKeyword() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: "#  include \"spaced.h\""
        )
        XCTAssertEqual(result, ["spaced.h"])
    }

    // MARK: - Path in include string

    func test_includeWithSubdirectoryPath() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: #"#include "path/to/types.h""#
        )
        XCTAssertEqual(result, ["path/to/types.h"])
    }

    // MARK: - Empty input

    func test_emptySource_returnsEmpty() {
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: "")
        XCTAssertTrue(result.isEmpty)
    }

    func test_sourceWithNoIncludes_returnsEmpty() {
        let result = ClangIncludeFinder.extractIncludePaths(
            sourceFileContent: "int main() { return 0; }"
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Aggregation order

    /// Several sources on the one wire: the aggregate is their include lists in wire-key
    /// order, whichever order the input dictionary offers them in. The aggregate is the
    /// node's output value, so an order that differed from run to run would give the same
    /// set of sources a different hash and every consumer of it a cache miss.
    func test_aggregatesTheSourceFilesInWireKeyOrder() throws {
        let names = ["src/e.c", "src/b.c", "src/f.c", "src/a.c", "src/d.c", "src/c.c"]
        var wires: [String: NodeValue] = [:]
        for name in names {
            wires[name] = .value(try "#include \"\(Self.headerName(forSource: name))\"\n".intern())
        }

        let finder = try ClangIncludeFinder(thisNode: NodeRecord(id: 1, kind: ClangIncludeFinder.kind))
        let inputs = try ClangIncludeFinder.ClangIncludeFinderInputs(
            input: ProcessInput(inputValues: [ClangIncludeFinder.sourceFileInputPort: wires]))
        let outputs = try finder.process(inputs: inputs)

        let expected = names.sorted().map { "src/" + Self.headerName(forSource: $0) }.joined()
        XCTAssertEqual(try outputs.includePathList.expectValue().resolveAsString(), expected)
    }

    /// `src/b.c` includes `b.h`: one header per source, named after it, so the aggregate
    /// says which source contributed which part of it.
    private static func headerName(forSource path: String) -> String {
        String(path.dropLast(2).suffix(1)) + ".h"
    }
}
