//
//  ClangPreludeTests.swift
//  SemelCLITests
//
//  B-108. `include 'clang'` must build what the hand-written chain builds — not merely
//  products with the same bytes, but the same nodes, so a formula that moves to
//  `clang.executable(…)` keeps its graph and its cache. Here because this is the one target
//  that sees the engine, which parses, and SemelClang, which provides the text.
//

@testable import SemelClang
@testable import SemelCore
import SemelNodeKit
import XCTest

final class ClangPreludeTests: XCTestCase {

    private let basePath = Path("input:/proj")

    /// Two sources and one pattern that matches nothing, as a C-only folder has for `*.cpp`.
    private func sources(_ pattern: String) -> [String] {
        pattern == "input:/proj/src/*.c" ? ["input:/proj/src/hello.c", "input:/proj/src/main.c"] : []
    }

    private func parse(_ formula: String) throws -> [String: GraphSpecNode] {
        let preludeSpec = FormulaPrelude.spec(forIncludeNamed: "clang").asString(omitOutputPort: false)
        let preludeText = FormulaPrelude.publishedText(namespace: "clang", text: SemelClang.prelude)
        return try FormulaFile.parse(formula, basePath: basePath,
                                     wildcardExpander: sources,
                                     includeReader: { $0.asString(omitOutputPort: false) == preludeSpec ? preludeText : nil })
    }

    /// The chain `EndToEnd/Fixtures/c/hello.fmla` wired by hand before B-108, over the two
    /// files B-109 gave it: the project's choices laid over the machine's facts.
    private let handWritten = """
        func rawConfig() = ConfigMerger(base: [StaticFile(path: <../semel.machine.config>)], override: [StaticFile(path: <semel.config>)])

        func config(prefix) = ConfigFilter(prefix: prefix, input: [rawConfig()])

        func preprocessor(path) = ClangPreprocessor(
          configuration: [config(prefix: 'clang.preprocessor')],
          input: [path: StaticFile(path: path)]
        )

        func make(glob, dynamicLibrary) = ClangLinker(
          configuration: [Configuration(base: [config(prefix: 'clang.linker')], dynamicLibrary: dynamicLibrary)],
          objectFiles: [{f: glob} "%%f%%.o": ClangCompiler(configuration: [config(prefix: 'clang.compiler')], input: ["%%f%%.p": preprocessor(path: f)])]
        )

        product "hello.dylib" = make(dynamicLibrary: 'true', glob: <src/*.c>)
        product "hello" = make(dynamicLibrary: 'false', glob: <src/*.c>)
        """

    private let withPrelude = """
        include 'clang'

        func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)

        product "hello.dylib" = clang.dynamicLibrary(sources: <src>, settings: settings())
        product "hello" = clang.executable(sources: <src>, settings: settings())
        """

    func test_thePreludeBuildsTheNodesTheHandWrittenChainBuilds() throws {
        let expected = try parse(handWritten)
        let actual   = try parse(withPrelude)

        XCTAssertEqual(Set(actual.keys), ["hello", "hello.dylib"])
        for product in expected.keys.sorted() {
            XCTAssertEqual(try XCTUnwrap(actual[product]).asString(omitOutputPort: false),
                           try XCTUnwrap(expected[product]).asString(omitOutputPort: false),
                           product)
        }
    }

    /// The archive's chain wired by hand: the same compiler per file as the linker's,
    /// under a `ClangArchiver` selecting its own namespace (B-79).
    private let handWrittenArchive = """
        func rawConfig() = ConfigMerger(base: [StaticFile(path: <../semel.machine.config>)], override: [StaticFile(path: <semel.config>)])

        func config(prefix) = ConfigFilter(prefix: prefix, input: [rawConfig()])

        func preprocessor(path) = ClangPreprocessor(
          configuration: [config(prefix: 'clang.preprocessor')],
          input: [path: StaticFile(path: path)]
        )

        product "libhello.a" = ClangArchiver(
          configuration: [config(prefix: 'clang.archiver')],
          objectFiles: [{f: <src/*.c>} "%%f%%.o": ClangCompiler(configuration: [config(prefix: 'clang.compiler')], input: ["%%f%%.p": preprocessor(path: f)])]
        )
        """

    private let archiveWithPrelude = """
        include 'clang'

        func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)

        product "libhello.a" = clang.staticLibrary(sources: <src>, settings: settings())
        """

    /// The shape a project whose files are not one folder's worth writes — Lua names the
    /// library's files itself (B-79): the same nodes, from `clang.compiled` per named file.
    private let archiveFromNamedFiles = """
        include 'clang'

        func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)

        product "libhello.a" = ClangArchiver(
          configuration: [clang.selected(settings: settings(), prefix: 'clang.archiver')],
          objectFiles: [{f: <src/hello.c>, <src/main.c>} "%%f%%.o": clang.compiled(file: f, settings: settings())]
        )
        """

    func test_theStaticLibraryFuncBuildsTheNodesTheHandWrittenArchiveChainBuilds() throws {
        let expected = try XCTUnwrap(try parse(handWrittenArchive)["libhello.a"]).asString(omitOutputPort: false)

        XCTAssertEqual(try XCTUnwrap(try parse(archiveWithPrelude)["libhello.a"]).asString(omitOutputPort: false), expected)
        XCTAssertEqual(try XCTUnwrap(try parse(archiveFromNamedFiles)["libhello.a"]).asString(omitOutputPort: false), expected)
    }

    func test_registeringSemelClangAnswersTheIncludeName() throws {
        FormulaIncludeProviders.removeAll()
        try SemelClang.register()

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "clang"),
                       .prelude(namespace: "clang", text: SemelClang.prelude))
    }
}
