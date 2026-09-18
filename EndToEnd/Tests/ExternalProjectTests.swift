//
//  ExternalProjectTests.swift
//  SemelEndToEndTests
//
//  Real projects pinned by commit. Skipped unless SEMEL_E2E_EXTERNAL=1, because they
//  fetch, vendor and build for minutes; nightly in CI, on demand for a developer.
//

import XCTest

final class ExternalProjectTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
    }

    func test_icecubesPackagesBuildTwiceForTheSimulator() throws {
        let run = try EndToEndRun(project: Projects.icecubes)
        do {
            try run.run()
        } catch {
            XCTFail("icecubes\n\(error)")
        }
    }

    func test_everyExternalProjectInTheRosterHasATestHere() {
        XCTAssertEqual(Set(Projects.external.map(\.name)), ["icecubes"])
    }
}
