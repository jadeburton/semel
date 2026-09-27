//
//  ExternalProjectTests.swift
//  SemelEndToEndTests
//
//  Real projects pinned by commit. Skipped unless SEMEL_E2E_EXTERNAL=1, because they
//  fetch, vendor and build for minutes; nightly in CI, on demand for a developer.
//

import XCTest

final class ExternalProjectTests: XCTestCase {

    func test_icecubesPackagesBuildTwiceForTheSimulator() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.icecubes)
        do {
            try run.run()
        } catch {
            XCTFail("icecubes\n\(error)")
        }
    }

    func test_icecubesAppBuildsTwiceForTheSimulator() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.icecubesApp)
        do {
            try run.run()
        } catch {
            XCTFail("icecubes-app\n\(error)")
        }
    }

    /// B-78: Semel builds Semel. Needs the network for GRDB, like the others; otherwise
    /// it is a fixture's size, and it runs every hermeticity build.
    func test_semelBuildsItself() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.semel)
        do {
            try run.run()
        } catch {
            XCTFail("semel\n\(error)")
        }
    }

    func test_everyExternalProjectInTheRosterHasATestHere() {
        XCTAssertEqual(Set(Projects.external.map(\.name)), ["icecubes", "icecubes-app", "semel"])
    }
}
