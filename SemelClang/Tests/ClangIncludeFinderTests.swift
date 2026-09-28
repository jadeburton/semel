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

    /// Objective-C's `#import` names a file as `#include` does; `@import` names a module,
    /// which is no file anyone pushes, and a line of it is passed over (B-77).
    func test_extractsQuotedImportAndPassesOverAModuleImport() {
        let source = """
            @import Foundation;
            #import "../FMDatabase.h"
            # import "FMResultSet.h"
            #import <sqlite3.h>
            @import AppKit.NSMenu;
            """
        let result = ClangIncludeFinder.extractIncludePaths(sourceFileContent: source)
        XCTAssertEqual(result, ["../FMDatabase.h", "FMResultSet.h"])
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

        let expected = names.sorted().map { "src/" + Self.headerName(forSource: $0) }.joined(separator: "\n")
        XCTAssertEqual(try outputs.includePathList.expectValue().resolveAsString(), expected)
    }

    /// Two sources on the one wire, each with two includes: the aggregate is a path per
    /// line throughout, including where one source's list meets the next. Without a
    /// separator at that seam the last path of one source and the first of the next read
    /// as one line, which names a file that does not exist; the consumer splits this
    /// value on newlines to learn which headers to wire.
    func test_aggregatesWithOnePathPerLineAcrossSources() throws {
        let wires: [String: NodeValue] = [
            "src/a.c": .value(try "#include \"a1.h\"\n#include \"a2.h\"\n".intern()),
            "src/b.c": .value(try "#include \"b1.h\"\n#include \"b2.h\"\n".intern()),
        ]

        let finder = try ClangIncludeFinder(thisNode: NodeRecord(id: 1, kind: ClangIncludeFinder.kind))
        let inputs = try ClangIncludeFinder.ClangIncludeFinderInputs(
            input: ProcessInput(inputValues: [ClangIncludeFinder.sourceFileInputPort: wires]))
        let outputs = try finder.process(inputs: inputs)

        let aggregate = try outputs.includePathList.expectValue().resolveAsString()
        XCTAssertEqual(aggregate.split(separator: "\n").map(String.init),
                       ["src/a1.h", "src/a2.h", "src/b1.h", "src/b2.h"])
    }

    // MARK: - Includes that leave the source's folder

    /// A source in a nested folder including its parent's header names the header's own
    /// node: the preprocessor wires a `StaticFile` at each listed path, and
    /// `src/lib/../hello.h` is a path nobody ever pushes.
    func test_anIncludeFromANestedFolderToItsParentNamesTheParentsHeader() throws {
        let wires: [String: NodeValue] = [
            "input:/src/lib/greet.c": .value(try "#include \"../hello.h\"\n#include \"./greet.h\"\n".intern()),
        ]

        let aggregate = try Self.includePathList(of: wires)

        XCTAssertEqual(aggregate, "input:/src/hello.h\ninput:/src/lib/greet.h")
    }

    /// Above the file system's root there is no node to name, so the include is left out
    /// and clang reports it as a file it cannot find, which is what it is.
    func test_anIncludeThatClimbsAboveTheRootIsLeftOut() throws {
        let wires: [String: NodeValue] = [
            "input:/main.c": .value(try "#include \"../hello.h\"\n#include \"main.h\"\n".intern()),
        ]

        let aggregate = try Self.includePathList(of: wires)

        XCTAssertEqual(aggregate, "input:/main.h")
    }

    private static func includePathList(of wires: [String: NodeValue]) throws -> String {
        let finder = try ClangIncludeFinder(thisNode: NodeRecord(id: 1, kind: ClangIncludeFinder.kind))
        let inputs = try ClangIncludeFinder.ClangIncludeFinderInputs(
            input: ProcessInput(inputValues: [ClangIncludeFinder.sourceFileInputPort: wires]))
        return try finder.process(inputs: inputs).includePathList.expectValue().resolveAsString()
    }

    // MARK: - A source nobody pushed (B-79)

    // The finder reads every quoted include, conditional or not, so the preprocessor asks
    // for a finder on headers that exist on no machine this builds on — SQLite's
    // amalgamation names `windows.h` and a configure step's `sqlite_cfg.h`. Such a file
    // includes nothing; whether it is needed is clang's to say.

    func test_aSourceNobodyPushedListsNoIncludes() throws {
        let wires: [String: NodeValue] = [
            "src/a.c":       .value(try "#include \"a1.h\"\n".intern()),
            "src/windows.h": .noValue(reason: .initializing),
        ]

        let finder = try ClangIncludeFinder(thisNode: NodeRecord(id: 1, kind: ClangIncludeFinder.kind))
        let inputs = try ClangIncludeFinder.ClangIncludeFinderInputs(
            input: ProcessInput(inputValues: [ClangIncludeFinder.sourceFileInputPort: wires]))
        let outputs = try finder.process(inputs: inputs)

        XCTAssertEqual(try outputs.includePathList.expectValue().resolveAsString(), "src/a1.h")
    }

    /// Only a file nobody pushed is read as absent: a source that failed upstream, or one
    /// that was pushed and then removed, still stops the finder.
    func test_aSourceInErrorOrDeletedStillFails() throws {
        for reason in [NoValueReason.inputInError, .deleted, .error(messageDataObjectHash: try "broken".intern())] {
            let wires: [String: NodeValue] = ["src/a.h": .noValue(reason: reason)]
            XCTAssertThrowsError(try ClangIncludeFinder.ClangIncludeFinderInputs(
                input: ProcessInput(inputValues: [ClangIncludeFinder.sourceFileInputPort: wires])),
                "\(reason)")
        }
    }

    /// So a report does not name the absent header as a file to push.
    func test_theSourcePortToleratesAnAbsentValue() {
        XCTAssertTrue(ClangIncludeFinder.descriptor.toleratesAbsentValue(onInputPort: ClangIncludeFinder.sourceFileInputPort))
    }

    /// `src/b.c` includes `b.h`: one header per source, named after it, so the aggregate
    /// says which source contributed which part of it.
    private static func headerName(forSource path: String) -> String {
        String(path.dropLast(2).suffix(1)) + ".h"
    }
}
