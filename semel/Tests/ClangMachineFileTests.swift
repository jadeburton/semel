//
//  ClangMachineFileTests.swift
//  SemelCLITests
//
//  B-119. `semel-clang` writes the machine file for the clang tools outside Semel: the
//  namespaces SemelClang registers as its own — those the formulas reading the file
//  select, when there are any — added to a file another writer wrote (B-109), left alone
//  when the file holds them already, and rewritten when told to. The machine's tools are
//  handed in, so nothing here depends on what is installed.
//

import Foundation
import SemelClang
import SemelClangTool
import SemelMachineFile
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
                                         notInstalled: [], selectedBy: [], merge: nil))
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
                                         notInstalled: [], selectedBy: ["hello/hello.fmla"], merge: nil))
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
                                         notInstalled: [], selectedBy: ["lua/lua.fmla"], merge: nil))
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
                                         notInstalled: [], selectedBy: [], merge: nil))
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
                                         notInstalled: [], selectedBy: [], merge: nil))
    }

    private func writeFormula(_ text: String, at relativePath: String) throws {
        let formula = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: formula.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: formula, atomically: true, encoding: .utf8)
    }

    // MARK: - A file that is already there (B-109)

    private let swiftc = ToolDescriptor(name: "swiftc", version: "Apple Swift 6.3", platform: "macOS",
                                        architecture: "arm64", recursiveHash: nil)

    /// The Swift namespaces as `semel-swift prepare` writes them, through the one writer.
    private func prepareWrote(_ namespaces: [String]) throws {
        try SemelSwift.register()
        try SemelClang.register()
        let entries = ToolNamespaceRegistry.all.filter { namespaces.contains($0.namespace) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try MachineFile.text(writtenBy: "semel-swift prepare", platform: .macos, descriptors: [swiftc, clang],
                             namespaces: entries)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    /// A formula that includes both the `clang` and the `swift` preludes reads both
    /// toolchains' namespaces out of one file, so a file `prepare` wrote gets the clang
    /// namespaces added and keeps its own, each part under its writer's header.
    func test_addsItsNamespacesToAFileAnotherWriterWroteAndKeepsTheirs() throws {
        try prepareWrote(["swift.compiler", "swift.linker"])
        try writeFormula("""
            include 'clang'
            include 'swift'
            func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)
            product "hello" = clang.executable(sources: <src>, settings: settings())
            """, at: "hello/hello.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        let kept = [MachineFile.Kept(writer: "semel-swift prepare", namespaces: ["swift.compiler", "swift.linker"])]
        XCTAssertEqual(outcome, .written(file, namespaces: ["clang.compiler", "clang.linker", "clang.preprocessor"],
                                         notInstalled: [], selectedBy: ["hello/hello.fmla"],
                                         merge: MachineFile.Merge(rewritten: [], kept: kept)))
        XCTAssertEqual(outcome.lines.first,
                       "Added clang.compiler, clang.linker, clang.preprocessor to \(file.path); "
                     + "kept swift.compiler, swift.linker from semel-swift prepare")

        let written = try contents()
        XCTAssertTrue(written.hasPrefix("// Written by semel-swift prepare for --platform macos"), written)
        XCTAssertTrue(written.contains("\n\n// Written by semel-clang for --platform macos"), written)
        XCTAssertTrue(written.contains("swift.compiler.toolDescriptor.name=swiftc"), written)
        XCTAssertTrue(written.contains("clang.compiler.toolDescriptor.name=clang"), written)
        XCTAssertEqual(MachineFile.sections(in: written).map(\.writer), ["semel-swift prepare", "semel-clang"])
    }

    /// A namespace is written once: one `prepare` wrote for a tree with a C target is taken
    /// out of its part when this tool writes it, and the rest of that part stays.
    func test_takesTheNamespacesItWritesOutOfAnotherWritersPart() throws {
        try prepareWrote(["clang.compiler", "swift.compiler"])

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: true) { [clang, libtool] }

        guard case .written(_, _, _, _, let merge) = outcome else {
            return XCTFail("expected a written file, got \(outcome)")
        }
        XCTAssertEqual(merge?.rewritten, ["clang.compiler"])
        XCTAssertEqual(merge?.kept, [MachineFile.Kept(writer: "semel-swift prepare", namespaces: ["swift.compiler"])])
        let sections = MachineFile.sections(in: try contents())
        XCTAssertEqual(sections.map(\.namespaces), [["swift.compiler"],
                                                     ["clang.archiver", "clang.compiler", "clang.linker", "clang.preprocessor"]])
    }

    /// The same machine gives the same answer, so a file that already holds what this tool
    /// would write is left as it is, whoever wrote it.
    func test_leavesAFileThatHoldsItsNamespacesAsItIs() throws {
        _ = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }
        let first = try contents()

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [] }

        XCTAssertEqual(outcome, .kept(file, namespaces: ["clang.archiver", "clang.compiler", "clang.linker", "clang.preprocessor"]))
        XCTAssertEqual(outcome.lines, ["Kept \(file.path): it holds clang.archiver, clang.compiler, clang.linker, "
                                     + "clang.preprocessor already; --force rewrites them"])
        XCTAssertEqual(try contents(), first)
    }

    /// A formula that stops selecting a namespace has it dropped from this tool's part on
    /// the next run, with no `--force`: a block nothing selects is reported as unused keys.
    func test_aNamespaceNoLongerSelectedGoesFromItsPart() throws {
        _ = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }
        try writeFormula("""
            include 'clang'
            func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)
            product "hello" = clang.executable(sources: <src>, settings: settings())
            """, at: "hello/hello.fmla")

        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [clang, libtool] }

        XCTAssertEqual(outcome.lines.first,
                       "Rewrote clang.compiler, clang.linker, clang.preprocessor in \(file.path)")
        XCTAssertFalse(try contents().contains("clang.archiver"))
    }

    /// After a toolchain update the file names a clang that is gone; `--force` rewrites it.
    func test_forceRewritesAMachineFileThatIsAlreadyThere() throws {
        _ = try ClangMachineFile.write(into: folder, platform: .macos, force: false) {
            [ToolDescriptor(name: "clang", version: "old", platform: "macOS", architecture: "arm64", recursiveHash: nil)]
        }

        _ = try ClangMachineFile.write(into: folder, platform: .macos, force: true) { [clang] }

        let written = try contents()
        XCTAssertTrue(written.contains("clang.compiler.toolDescriptor.version=Apple clang 21"), written)
        XCTAssertFalse(written.contains("version=old"), written)
        XCTAssertEqual(MachineFile.sections(in: written).count, 1, written)
    }

    /// A machine with no clang and no libtool still gets a file, whose blocks are comments,
    /// and the tool says which tools it did not find.
    func test_aToolNotInstalledIsNamed() throws {
        let outcome = try ClangMachineFile.write(into: folder, platform: .macos, force: false) { [] }

        guard case .written(_, _, let notInstalled, _, _) = outcome else {
            return XCTFail("expected a written file, got \(outcome)")
        }
        XCTAssertEqual(notInstalled, ["clang", "libtool"])
        let written = try contents()
        XCTAssertTrue(written.contains("no clang is installed"), written)
        XCTAssertTrue(written.contains("no libtool is installed"), written)
    }
}
