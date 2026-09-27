//
//  MaterialiseTests.swift
//  SemelEndToEndTests
//
//  The two steps before any build, on their own: they are fast, and a failure here is
//  about the tree or the machine, not about Semel.
//

import XCTest

final class MaterialiseTests: XCTestCase {

    private var run: EndToEndRun?

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_aFixtureRunCopiesTheWholeTreeUnderAShortRoot() throws {
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run

        try run.materialise()

        XCTAssertTrue(run.root.path.hasPrefix("/tmp/semel-tests/"), run.root.path)
        XCTAssertLessThan(run.root.appendingPathComponent("home3/semelserv.sock").path.utf8.count, 104)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("c/hello.fmla").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("swift/HelloApp/semel.fmla").path))
    }

    /// B-109. The machine file beside the C fixtures says what this machine has — the
    /// clang the descriptor names and the SDK where the linker reads it — for the clang
    /// namespaces and no other.
    func test_configureWritesTheMachineFileTheCFixturesRead() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run
        try run.materialise()

        try run.configure()

        let written = try String(contentsOf: run.base.appendingPathComponent("semel.machine.config"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("// Written by semel-clang for --platform macos"), written)
        XCTAssertTrue(written.contains("clang.linker.toolDescriptor.version=" + (try MachineFacts.clangVersion())), written)
        XCTAssertTrue(written.contains("clang.linker.sdkPath=" + (try MachineFacts.macOSSDKPath())), written)
        XCTAssertFalse(written.contains("swift."), "the clang namespaces only: \(written)")
    }

    func test_configurePreparesAProjectWithAPlatform() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.swiftMyApp)
        self.run = run
        try run.materialise()

        try run.configure()

        let config = try String(contentsOf: run.base.appendingPathComponent("swift/MyApp/semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-macosx13.0"), config)
        XCTAssertFalse(config.contains("clang.linker"), "a package tree never links through clang")
    }
}
