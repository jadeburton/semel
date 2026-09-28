//
//  ClangMachineFileTests.swift
//  SemelCLITests
//
//  B-119. `semel-clang` writes the machine file for the clang tools outside Semel: the
//  namespaces SemelClang registers as its own — those the formulas reading the file
//  select, when there are any — only when the folder has none, and again when told to. The machine's tools are handed in, so nothing here depends on what is
//  installed.
//

import Foundation
import SemelClangTool
import SemelNodeKit
import SemelSwift
import XCTest

final class ClangMachineFileTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-clang-tests/\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private let clang = ToolDescriptor(name: "clang", version: "Apple clang 21", platform: "macOS",
                                       architecture: "arm64", recursiveHash: nil)
    private let libtool = ToolDescriptor(name: "libtool", version: "Apple Inc. version cctools_ld-1267", platform: "macOS",
                                         architecture: "arm64", recursiveHash: nil)

    private var file: URL { folder.appendingPathComponent("semel.machine.config") }

    private func contents() throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    func test_writesTheClangNamespacesAndNoOther() throws {
        // Another toolchain registered in the same process is not this tool's to write.
        try SemelSwift.register()

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.archiver", "clang.compiler", "clang.linker", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: []))
        let written = try contents()
        XCTAssertTrue(written.hasPrefix("// Written by semel-clang for --platform macos"), written)
        XCTAssertTrue(written.contains("clang.compiler.toolDescriptor.version=Apple clang 21"), written)
        XCTAssertTrue(written.contains("clang.linker.toolDescriptor.name=clang"), written)
        XCTAssertTrue(written.contains("clang.archiver.toolDescriptor.name=libtool"), written)
        XCTAssertTrue(written.contains("clang.archiver.toolDescriptor.version=Apple Inc. version cctools_ld-1267"), written)
        XCTAssertFalse(written.contains("swift."), written)
    }

    /// The tutorial's project, as the tutorial lays it out: `hello/hello.fmla` reads
    /// `<../semel.machine.config>` and links an executable and a dynamic library, so the
    /// archiver's block would be keys no filter selects, reported as unused on every build.
    func test_writesTheNamespacesTheFormulasReadingTheFileSelect() throws {
        let tutorial = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../EndToEnd/Fixtures/tutorial/hello.fmla").standardizedFileURL
        try writeFormula(try String(contentsOf: tutorial, encoding: .utf8), at: "hello/hello.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.compiler", "clang.linker", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: ["hello/hello.fmla"]))
        let written = try contents()
        XCTAssertFalse(written.contains("clang.archiver"), written)
    }

    /// Lua's formula archives its library through `clang.selected(…, prefix: 'clang.archiver')`
    /// in its own text and compiles through `clang.compiled`, which reaches the preprocessor.
    func test_aPrefixInTheFormulaAndThePreludeFuncsItCallsBothCount() throws {
        try writeFormula("""
            include 'clang'
            func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)
            product "liblua.a" = ClangArchiver(
              configuration: [clang.selected(settings: settings(), prefix: 'clang.archiver')],
              objectFiles: [{f: <*.c>} "%%f%%.o": clang.compiled(file: f, settings: settings())]
            )
            """, at: "lua/lua.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.archiver", "clang.compiler", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: ["lua/lua.fmla"]))
    }

    /// Only a formula that reads this file counts: one naming a machine file of its own,
    /// beside it, is another project's business.
    func test_aFormulaReadingAnotherMachineFileDoesNotCount() throws {
        try writeFormula("""
            include 'clang'
            func settings() = clang.settings(project: <semel.config>, machine: <semel.machine.config>)
            product "hello" = clang.executable(sources: <src>, settings: settings())
            """, at: "other/other.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.archiver", "clang.compiler", "clang.linker", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: []))
    }

    /// A formula whose clang namespaces cannot be read from its text gets every one: a
    /// file with none would leave every tool without its settings.
    func test_aFormulaThatSelectsNoClangNamespaceGetsEveryOne() throws {
        try writeFormula("""
            include SwiftFormulaConverter(path: <.>, root: <.>).formula
            func settings() = StaticFile(path: <semel.machine.config>)
            """, at: "semel.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.archiver", "clang.compiler", "clang.linker", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: []))
    }

    private func writeFormula(_ text: String, at relativePath: String) throws {
        let formula = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: formula.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: formula, atomically: true, encoding: .utf8)
    }

    /// A file already there may hold another toolchain's namespaces beside the clang ones —
    /// `semel-swift prepare` writes both for a tree with a C-family target — so it is kept.
    func test_keepsAMachineFileThatIsAlreadyThere() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "swift.compiler.toolDescriptor.name=swiftc\n".write(to: file, atomically: true, encoding: .utf8)

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang] }

        XCTAssertEqual(outcome, .kept(file))
        XCTAssertEqual(try contents(), "swift.compiler.toolDescriptor.name=swiftc\n")
    }

    /// After a toolchain update the file names a clang that is gone; `--force` rewrites it.
    func test_forceRewritesAMachineFileThatIsAlreadyThere() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "clang.compiler.toolDescriptor.version=old\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try ClangMachineFile.write(into: folder, platform: .macos, force: true) { [clang] }

        XCTAssertTrue(try contents().contains("clang.compiler.toolDescriptor.version=Apple clang 21"))
    }

    /// A machine with no clang and no libtool still gets a file, whose blocks are comments,
    /// and the tool says which tools it did not find.
    func test_aToolNotInstalledIsNamed() throws {
        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [] }

        guard case .written(_, _, let notInstalled, _) = outcome else {
            return XCTFail("expected a written file, got \(outcome)")
        }
        XCTAssertEqual(notInstalled, ["clang", "libtool"])
        let written = try contents()
        XCTAssertTrue(written.contains("no clang is installed"), written)
        XCTAssertTrue(written.contains("no libtool is installed"), written)
    }
}
