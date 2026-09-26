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
                                     includeReader: { $0 == preludeSpec ? preludeText : nil })
    }

    /// The chain `EndToEnd/Fixtures/c/hello.fmla` wires by hand.
    private let handWritten = """
        func rawConfig() = StaticFile(path: <../clang.cfg>)

        func config(prefix) = ConfigFilter(prefix: prefix, input: [rawConfig()])

        func preprocessor(path) = ClangPreprocessor(
          configuration: [config(prefix: 'clang.preprocessor')],
          input: [path: StaticFile(path: path)]
        )

        func make(glob, dynamicLibrary) = ClangLinker(
          configuration: [Configuration(inherit: [config(prefix: 'clang.linker')], dynamicLibrary: dynamicLibrary)],
          objectFiles: [{f: glob} "%%f%%.o": ClangCompiler(configuration: [config(prefix: 'clang.compiler')], input: ["%%f%%.p": preprocessor(path: f)])]
        )

        product "hello.dylib" = make(dynamicLibrary: 'true', glob: <src/*.c>)
        product "hello" = make(dynamicLibrary: 'false', glob: <src/*.c>)
        """

    private let withPrelude = """
        include 'clang'

        product "hello.dylib" = clang.dynamicLibrary(sources: <src>, settings: <../clang.cfg>)
        product "hello" = clang.executable(sources: <src>, settings: <../clang.cfg>)
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

    func test_registeringSemelClangAnswersTheIncludeName() throws {
        FormulaIncludeProviders.removeAll()
        try SemelClang.register()

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "clang"),
                       .prelude(namespace: "clang", text: SemelClang.prelude))
    }
}
