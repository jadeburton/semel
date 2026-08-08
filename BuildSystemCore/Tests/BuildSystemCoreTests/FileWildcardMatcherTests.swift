@testable import BuildSystemCore
import XCTest

final class FileWildcardMatcherTests: XCTestCase {

    // MARK: - Mock input

    private struct MockInput: FileWildcardMatcherInput {
        let rootDirectoryPath: String = "/"
        let entriesByDirectory: [String: [FileWildcardEntry]]

        func allFiles(inDirectoryPath path: String) throws -> [FileWildcardEntry] {
            entriesByDirectory[path] ?? []
        }
    }

    private func file(_ name: String) -> FileWildcardEntry {
        FileWildcardEntry(path: Path(name), kind: .file, isMissing: false, isUnreferenced: false)
    }

    private func folder(_ name: String) -> FileWildcardEntry {
        FileWildcardEntry(path: Path(name), kind: .folder, isMissing: false, isUnreferenced: false)
    }

    private func matcher(
        root: [FileWildcardEntry],
        subdirs: [String: [FileWildcardEntry]] = [:]
    ) -> FileWildcardMatcher {
        var all: [String: [FileWildcardEntry]] = ["/": root]
        for (dir, entries) in subdirs { all[dir] = entries }
        return FileWildcardMatcher(input: MockInput(entriesByDirectory: all))
    }

    // MARK: - Exact name match

    func test_exactMatch_returnsMatchingFile() throws {
        let m = matcher(root: [file("hello.c"), file("main.c")])
        let results = try m.findAllMatching(pathOrWildcard: "hello.c")
        XCTAssertEqual(results.map(\.path.string), ["hello.c"])
    }

    func test_exactMatch_noMatchReturnsEmpty() throws {
        let m = matcher(root: [file("hello.c")])
        let results = try m.findAllMatching(pathOrWildcard: "missing.c")
        XCTAssertTrue(results.isEmpty)
    }

    func test_exactMatch_emptyRoot_returnsEmpty() throws {
        let m = matcher(root: [])
        let results = try m.findAllMatching(pathOrWildcard: "hello.c")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Star wildcard (single segment)

    func test_star_matchesByExtension() throws {
        let m = matcher(root: [file("hello.c"), file("main.c"), file("README")])
        let results = try m.findAllMatching(pathOrWildcard: "*.c")
        XCTAssertEqual(Set(results.map(\.path.string)), ["hello.c", "main.c"])
    }

    func test_star_doesNotDescendIntoSubdirectories() throws {
        let m = matcher(root: [folder("src")], subdirs: ["/src": [file("hello.c")]])
        let results = try m.findAllMatching(pathOrWildcard: "*.c")
        XCTAssertTrue(results.isEmpty)
    }

    func test_star_matchesEmptySuffix() throws {
        let m = matcher(root: [file("hello"), file("world")])
        let results = try m.findAllMatching(pathOrWildcard: "*")
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Question mark wildcard

    func test_questionMark_matchesSingleCharacter() throws {
        let m = matcher(root: [file("a.c"), file("ab.c"), file("b.c")])
        let results = try m.findAllMatching(pathOrWildcard: "?.c")
        XCTAssertEqual(Set(results.map(\.path.string)), ["a.c", "b.c"])
    }

    func test_questionMark_doesNotMatchEmpty() throws {
        let m = matcher(root: [file(".c")])
        let results = try m.findAllMatching(pathOrWildcard: "?.c")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Nested exact path

    func test_nestedPath_exactMatch() throws {
        let m = matcher(root: [folder("src")], subdirs: ["/src": [file("hello.c")]])
        let results = try m.findAllMatching(pathOrWildcard: "src/hello.c")
        XCTAssertEqual(results.map(\.path.string), ["src/hello.c"])
    }

    func test_nestedPath_fileSegmentIsFolder_noMatch() throws {
        // "src" exists but is a file, not a folder — cannot descend into it
        let m = matcher(root: [file("src")])
        let results = try m.findAllMatching(pathOrWildcard: "src/hello.c")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Star in nested path

    func test_star_inLastSegmentOfNestedPath() throws {
        let m = matcher(
            root: [folder("src")],
            subdirs: ["/src": [file("hello.c"), file("main.c"), file("notes.txt")]]
        )
        let results = try m.findAllMatching(pathOrWildcard: "src/*.c")
        XCTAssertEqual(Set(results.map(\.path.string)), ["src/hello.c", "src/main.c"])
    }

    func test_star_inFirstSegmentMatchesFolders() throws {
        let m = matcher(
            root: [folder("src"), folder("lib")],
            subdirs: ["/src": [file("a.c")], "/lib": [file("b.c")]]
        )
        let results = try m.findAllMatching(pathOrWildcard: "*/a.c")
        XCTAssertEqual(results.map(\.path.string), ["src/a.c"])
    }

    // MARK: - Globstar (**)

    func test_globstar_matchesZeroDirectoryLevels() throws {
        // ** with zero levels skips directly to *.c at root
        let m = matcher(root: [file("hello.c")])
        let results = try m.findAllMatching(pathOrWildcard: "**/*.c")
        XCTAssertTrue(results.map(\.path.string).contains("hello.c"))
    }

    func test_globstar_matchesOneDirectoryLevel() throws {
        let m = matcher(root: [folder("src")], subdirs: ["/src": [file("hello.c")]])
        let results = try m.findAllMatching(pathOrWildcard: "**/*.c")
        XCTAssertTrue(results.map(\.path.string).contains("src/hello.c"))
    }

    func test_globstar_matchesTwoDirectoryLevels() throws {
        let m = matcher(
            root: [folder("a")],
            subdirs: ["/a": [folder("b")], "/a/b": [file("deep.c")]]
        )
        let results = try m.findAllMatching(pathOrWildcard: "**/*.c")
        XCTAssertTrue(results.map(\.path.string).contains("a/b/deep.c"))
    }

    // MARK: - Result entry properties

    func test_resultEntry_preservesKind() throws {
        let m = matcher(root: [file("hello.c"), folder("src")])
        let results = try m.findAllMatching(pathOrWildcard: "src")
        XCTAssertEqual(results.first?.kind, .folder)
    }

    func test_resultEntry_logicalPathStartsFromRoot() throws {
        let m = matcher(root: [folder("src")], subdirs: ["/src": [file("main.c")]])
        let results = try m.findAllMatching(pathOrWildcard: "src/main.c")
        // Path should be the full logical path relative to the root, not just the filename
        XCTAssertEqual(results.first?.path.string, "src/main.c")
    }
}
