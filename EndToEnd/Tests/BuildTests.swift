//
//  BuildTests.swift
//  SemelEndToEndTests
//
//  One cold build of the smallest fixture, on its own, so a failure in the server
//  lifecycle or the export shows up before the full run's diff does.
//

import XCTest

final class BuildTests: XCTestCase {

    private var run: EndToEndRun?

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_cHelloBuildsColdAndExportsItsProducts() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run
        try run.materialise()
        try run.configure()

        let out = try run.coldBuild(home: "home1", out: "out1")

        XCTAssertNoThrow(try run.checkProducts(in: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("home1/semelserv.sock").path))
        let config = try String(contentsOf: out.appendingPathComponent("config.txt"), encoding: .utf8)
        XCTAssertFalse(config.contains("${"), "config.txt is the rendered config, pushed whole")
    }

    func test_cHelloBuildsTwiceToTheSameBytes() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)

        XCTAssertNoThrow(try run.run(), "see the failure's steps and tails")
    }
}
