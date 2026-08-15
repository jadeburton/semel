@testable import BuildSystemCore
import XCTest
import SemelNodeKit

final class IncludeFinderTests: BuildSystemTestCase {

    // MARK: - Basic extraction

    func test_extractsQuotedInclude() {
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: #"#include "hello.h""#)
        XCTAssertEqual(result, ["hello.h"])
    }

    func test_ignoresAngleBracketInclude() {
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: "#include <stdio.h>")
        XCTAssertTrue(result.isEmpty)
    }

    func test_extractsMultipleIncludes() {
        let source = """
            #include "a.h"
            #include "b.h"
            #include "c.h"
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["a.h", "b.h", "c.h"])
    }

    func test_mixedQuotedAndAngleBracket_returnsOnlyQuoted() {
        let source = """
            #include <stdio.h>
            #include "local.h"
            #include <stdlib.h>
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["local.h"])
    }

    // MARK: - Deduplication

    func test_deduplicatesRepeatedIncludes() {
        let source = """
            #include "hello.h"
            #include "hello.h"
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, "hello.h")
    }

    func test_deduplication_preservesFirstOccurrenceOrder() {
        let source = """
            #include "b.h"
            #include "a.h"
            #include "b.h"
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["b.h", "a.h"])
    }

    // MARK: - Comment stripping

    func test_includeInLineComment_isIgnored() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: #"// #include "hidden.h""#
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_includeInBlockComment_isIgnored() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: #"/* #include "hidden.h" */"#
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_includeAfterLineComment_isCaptured() {
        let source = """
            // this is a comment
            #include "real.h"
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["real.h"])
    }

    func test_multilineBlockComment_includeInsideIsIgnored() {
        let source = """
            /*
             * #include "inside_comment.h"
             */
            #include "outside.h"
            """
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["outside.h"])
    }

    // MARK: - Whitespace variants

    func test_includeWithTabIndent() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: "\t#include \"indented.h\""
        )
        XCTAssertEqual(result, ["indented.h"])
    }

    func test_includeWithSpacesBetweenHashAndKeyword() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: "#  include \"spaced.h\""
        )
        XCTAssertEqual(result, ["spaced.h"])
    }

    // MARK: - Path in include string

    func test_includeWithSubdirectoryPath() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: #"#include "path/to/types.h""#
        )
        XCTAssertEqual(result, ["path/to/types.h"])
    }

    // MARK: - Empty input

    func test_emptySource_returnsEmpty() {
        let result = IncludeFinder.extractIncludePaths(sourceFileContent: "")
        XCTAssertTrue(result.isEmpty)
    }

    func test_sourceWithNoIncludes_returnsEmpty() {
        let result = IncludeFinder.extractIncludePaths(
            sourceFileContent: "int main() { return 0; }"
        )
        XCTAssertTrue(result.isEmpty)
    }
}
