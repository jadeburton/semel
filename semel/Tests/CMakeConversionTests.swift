//
//  CMakeConversionTests.swift
//  SemelCLITests
//
//  B-156. `semel-cmake` over a folder on disk: the files it writes, the files it keeps,
//  and — here because this is the one target that sees the engine, which parses, and the
//  translator, which emits — that the formula it writes resolves to the products the
//  CMakeLists.txt declares, through the clang prelude, as a build would read it.
//

@testable import SemelClang
@testable import SemelCore
import Foundation
import SemelCMake
import SemelCMakeTool
import SemelNodeKit
import XCTest

final class CMakeConversionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cmake-tests/\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SemelClang.register()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private let descriptor = ToolDescriptor(name: "clang", version: "test-clang", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)

    private func convert() throws -> CMakeConversionReport {
        try CMakeConversion.run(folder: root, platform: .macos, descriptors: { [self.descriptor] })
    }

    /// The two-target project the emitter's own tests read, on disk.
    private func writeProject() throws {
        try write("CMakeLists.txt", """
            cmake_minimum_required(VERSION 3.16)
            project(hello LANGUAGES C)
            find_package(Threads)
            add_subdirectory(greet)
            add_executable(hello src/main.c)
            target_link_libraries(hello PRIVATE greet m)
            """)
        try write("greet/CMakeLists.txt", """
            add_library(greet STATIC greet.c)
            target_include_directories(greet PUBLIC include)
            target_compile_definitions(greet PRIVATE GREET_INTERNAL)
            """)
        try write("src/main.c", "int main(void) { return 0; }\n")
        try write("greet/greet.c", "int greet(void) { return 1; }\n")
        try write("greet/include/greet.h", "int greet(void);\n")
    }

    /// Parsed the way the builder parses it, with the clang prelude the formula includes.
    private func parse(_ formula: String) throws -> [String: GraphSpecNode] {
        let preludeSpec = FormulaPrelude.spec(forIncludeNamed: "clang").asString(omitOutputPort: false)
        let preludeText = FormulaPrelude.publishedText(namespace: "clang", text: SemelClang.prelude)
        return try FormulaFile.parse(formula, basePath: Path("input:/proj"),
                                     wildcardExpander: { _ in [] },
                                     includeReader: { $0.asString(omitOutputPort: false) == preludeSpec ? preludeText : nil })
    }

    // MARK: - Tests

    func test_theFormulaAndTheConfigAreWrittenOnceAndTheMachineFileBesideThem() throws {
        try writeProject()
        let first = try convert()
        XCTAssertEqual(first.projectName, "hello")
        XCTAssertEqual(first.target, "arm64-apple-macosx14.0")
        XCTAssertEqual(first.targets, [.init(name: "greet", kind: "static library", product: "libgreet.a"),
                                       .init(name: "hello", kind: "executable", product: "hello")])
        XCTAssertEqual(first.untranslated, ["CMakeLists.txt:3: find_package is not in the declarative subset"])
        XCTAssertEqual(first.written.map(\.lastPathComponent), ["semel.fmla", "semel.config"])
        XCTAssertEqual(first.kept, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("semel.machine.config").path))

        let formula = try read("semel.fmla")
        XCTAssertTrue(formula.contains("product 'libgreet.a' = greet()"), formula)
        XCTAssertTrue(formula.contains("objectFiles: [{file: <greet/greet.c>} \"%%file%%.o\": compiled_greet(file: file)]"), formula)
        XCTAssertTrue(formula.contains("headerFolders: ['00 greet/include': Folder(path: <greet/include>).manifest]"), formula)
        XCTAssertTrue(formula.contains("libraries: ['libgreet.a': greet()]"), formula)
        let config = try read("semel.config")
        XCTAssertTrue(config.contains("clang.compiler.target=arm64-apple-macosx14.0\nclang.compiler.cStandard=gnu17\n"), config)
        XCTAssertFalse(config.contains("cxxStandard"), config)

        // A second run keeps what the person may have edited since.
        try write("semel.fmla", "// edited\n")
        let second = try convert()
        XCTAssertEqual(second.written, [])
        XCTAssertEqual(second.kept.map(\.lastPathComponent), ["semel.fmla", "semel.config"])
        XCTAssertEqual(try read("semel.fmla"), "// edited\n")
    }

    func test_theWrittenFormulaResolvesToTheDeclaredProductsThroughThePrelude() throws {
        try writeProject()
        _ = try convert()
        let products = try parse(try read("semel.fmla"))
        XCTAssertEqual(Set(products.keys), ["libgreet.a", "hello"])
        let archive = try XCTUnwrap(products["libgreet.a"])
        XCTAssertEqual(archive.typeName, "ClangArchiver")
        let executable = try XCTUnwrap(products["hello"])
        XCTAssertEqual(executable.typeName, "ClangLinker")
        let libraries = try XCTUnwrap(executable.inputs.first { $0.portName == ClangLinker.libraries })
        XCTAssertEqual(libraries.wires.map(\.name), ["libgreet.a"])
        XCTAssertEqual(libraries.wires.map(\.node.typeName), ["ClangArchiver"])
        let objects = try XCTUnwrap(executable.inputs.first { $0.portName == ClangLinker.input })
        XCTAssertEqual(objects.wires.map(\.name), ["input:/proj/src/main.c.o"])
        XCTAssertEqual(objects.wires.map(\.node.typeName), ["ClangCompiler"])
    }

    func test_aFolderWithoutACMakeListsIsAnErrorNamingIt() throws {
        XCTAssertThrowsError(try convert()) { error in
            XCTAssertEqual("\(error)", "no CMakeLists.txt in \(root.path)")
        }
    }
}
