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

    /// B-79: a real C project, from a clone with the roster's formula laid over it (B-76).
    /// Needs the network for the clone; the build is seconds, so it runs every
    /// hermeticity build.
    func test_luaBuildsFromTheMirrorWithTheOverlaidFormula() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.lua)
        do {
            try run.run()
        } catch {
            XCTFail("lua\n\(error)")
        }
    }

    /// B-79: one very large translation unit — SQLite's amalgamation — through the
    /// preprocessor, the compiler and the cache, with the shell linked against it.
    func test_sqliteBuildsFromTheAmalgamation() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.sqlite)
        do {
            try run.run()
        } catch {
            XCTFail("sqlite\n\(error)")
        }
    }

    /// B-77: Apple's Food Truck sample for the simulator — file lists over groups, a
    /// localized `.strings`, a package with resources, a widget extension.
    func test_foodTruckBuildsTwiceForTheSimulator() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.foodTruck)
        do {
            try run.run()
        } catch {
            XCTFail("food-truck\n\(error)")
        }
    }

    /// B-77: the same sample for the Mac, over a clone with four files' ActivityKit guards
    /// corrected by the overlay (B-76). Seconds to build, so every hermeticity build runs.
    func test_foodTruckBuildsTwiceForTheMac() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.foodTruckMac)
        do {
            try run.run()
        } catch {
            XCTFail("food-truck-mac\n\(error)")
        }
    }

    func test_everyExternalProjectInTheRosterHasATestHere() {
        XCTAssertEqual(Set(Projects.external.map(\.name)),
                       ["icecubes", "icecubes-app", "semel", "lua", "sqlite", "food-truck", "food-truck-mac"])
    }
}
