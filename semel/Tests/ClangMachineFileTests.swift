//
//  ClangMachineFileTests.swift
//  SemelCLITests
//
//  B-119. `semel-clang` writes the machine file for the clang tools outside Semel: the
//  namespaces SemelClang registers as its own, only when the folder has none, and again
//  when told to. The machine's tools are handed in, so nothing here depends on what is
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
                                         notInstalled: []))
        let written = try contents()
        XCTAssertTrue(written.hasPrefix("// Written by semel-clang for --platform macos"), written)
        XCTAssertTrue(written.contains("clang.compiler.toolDescriptor.version=Apple clang 21"), written)
        XCTAssertTrue(written.contains("clang.linker.toolDescriptor.name=clang"), written)
        XCTAssertTrue(written.contains("clang.archiver.toolDescriptor.name=libtool"), written)
        XCTAssertTrue(written.contains("clang.archiver.toolDescriptor.version=Apple Inc. version cctools_ld-1267"), written)
        XCTAssertFalse(written.contains("swift."), written)
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

        guard case .written(_, _, let notInstalled) = outcome else {
            return XCTFail("expected a written file, got \(outcome)")
        }
        XCTAssertEqual(notInstalled, ["clang", "libtool"])
        let written = try contents()
        XCTAssertTrue(written.contains("no clang is installed"), written)
        XCTAssertTrue(written.contains("no libtool is installed"), written)
    }
}
