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

    /// B-79: C++ with heavy templates — simdjson's single-header amalgamation — through
    /// the preprocessor, the compiler and the archiver, with a demo linked against libc++.
    func test_simdjsonBuildsFromTheAmalgamation() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.simdjson)
        do {
            try run.run()
        } catch {
            XCTFail("simdjson\n\(error)")
        }
    }

    // MARK: - CMake projects, translated (B-166)

    /// B-166: the SQLite mirror read from its own CMakeLists.txt — a shared library beside
    /// the archive, and the defines the file states — with nothing laid over it.
    func test_sqliteBuildsFromItsCMakeLists() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.sqliteCMake)
        do {
            try run.run()
        } catch {
            XCTFail("sqlite-cmake\n\(error)")
        }
    }

    /// B-166: cJSON — options deciding a shared library, a tests subdirectory whose
    /// executables link it, and a `foreach` skipped whole.
    func test_cJSONBuildsFromItsCMakeLists() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cJSON)
        do {
            try run.run()
        } catch {
            XCTFail("cjson\n\(error)")
        }
    }

    /// B-166: LibTomMath — one archive from 154 listed sources with compile options over
    /// each, the widest fan-out of a translated project.
    func test_libtommathBuildsFromItsCMakeLists() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.libtommath)
        do {
            try run.run()
        } catch {
            XCTFail("libtommath\n\(error)")
        }
    }

    /// B-166: TinyXML-2 — Windows line ends, no language named, a header among the
    /// sources, and defines in generator expressions the archive does without.
    func test_tinyxml2BuildsFromItsCMakeLists() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.tinyxml2)
        do {
            try run.run()
        } catch {
            XCTFail("tinyxml2\n\(error)")
        }
    }

    /// B-166: pugixml — a generator expression over three lines, dependent options
    /// refused, and the static target under the output name the file gives it.
    func test_pugixmlBuildsFromItsCMakeLists() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.pugixml)
        do {
            try run.run()
        } catch {
            XCTFail("pugixml\n\(error)")
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

    /// B-77: NetNewsWire's Mac app — local packages, a vendored binary framework, C and
    /// Objective-C in packages and in the app, xibs, two extensions — over a clone with the
    /// generated `SecretKey.swift` laid by the overlay. Signed, verified deep and strict with
    /// Sparkle's links as links, and inspected, not run.
    func test_netNewsWireBuildsTwiceForTheMac() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.netNewsWireMac)
        do {
            try run.run()
        } catch {
            XCTFail("netnewswire-mac\n\(error)")
        }
    }

    /// B-77: NetNewsWire's iOS app for the simulator, from the same clone and overlay as
    /// the Mac app's: the application the platform picks, its Share and widget extensions,
    /// storyboards, Objective-C, the local packages. Inspected, not run: each executable
    /// records the SDK it was built with.
    func test_netNewsWireBuildsTwiceForTheSimulator() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.netNewsWireIOS)
        do {
            try run.run()
        } catch {
            XCTFail("netnewswire-ios\n\(error)")
        }
    }

    /// B-77: CodeEdit's Mac app from a fresh clone — thirty-four vendored packages, a static
    /// framework linked in and embedded nowhere, a hidden resource followed by its path, a
    /// package's bundle laid out for the Mac, Sparkle, a Finder Sync extension. Signed,
    /// verified deep and strict, and inspected, not run.
    func test_codeEditBuildsTwiceForTheMac() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.codeEdit)
        do {
            try run.run()
        } catch {
            XCTFail("codeedit\n\(error)")
        }
    }

    /// B-77 item 4: Sequel Ace's Mac app from a fresh clone — Objective-C with Swift beside
    /// it, lex scanners, a Core Data model, two framework targets of referenced projects,
    /// Firebase built from its packages, a command-line tool signed by itself. Signed,
    /// verified deep and strict, and inspected, not run.
    func test_sequelAceBuildsTwiceForTheMac() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.sequelAce)
        do {
            try run.run()
        } catch {
            XCTFail("sequel-ace\n\(error)")
        }
    }

    /// B-80: package macros built from swift-syntax — the macro's executable linked from
    /// every swift-syntax target it reaches and loaded by the library declaring its macros.
    func test_swiftDependenciesBuildsItsMacroFromSwiftSyntax() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.swiftDependencies)
        do {
            try run.run()
        } catch {
            XCTFail("swift-dependencies\n\(error)")
        }
    }

    /// B-80 item 2: swift-syntax from its own root, its nested packages not roots, every
    /// library product an archive.
    func test_swiftSyntaxBuildsFromItsOwnRoot() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.swiftSyntax)
        do {
            try run.run()
        } catch {
            XCTFail("swift-syntax\n\(error)")
        }
    }

    /// B-77 and B-80 item 1: Apple's Backyard Birds for the Mac — SwiftData's `@Model`
    /// from the platform's macro plugins, local packages at their roots with catalog
    /// symbols, a WidgetKit extension. Signed and verified deep and strict.
    func test_backyardBirdsBuildsForTheMac() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.backyardBirdsMac)
        do {
            try run.run()
        } catch {
            XCTFail("backyard-birds-mac\n\(error)")
        }
    }

    /// B-77: the same sample's iOS app for the simulator, the widget beside it.
    func test_backyardBirdsBuildsForTheSimulator() throws {
        try XCTSkipUnless(EndToEndEnvironment.runsExternal, "set SEMEL_E2E_EXTERNAL=1 to build the external projects")
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.backyardBirdsIOS)
        do {
            try run.run()
        } catch {
            XCTFail("backyard-birds-ios\n\(error)")
        }
    }

    func test_everyExternalProjectInTheRosterHasATestHere() {
        XCTAssertEqual(Set(Projects.external.map(\.name)),
                       ["icecubes", "icecubes-app", "semel", "lua", "sqlite", "simdjson", "food-truck", "food-truck-mac",
                        "netnewswire-mac", "netnewswire-ios", "codeedit", "sequel-ace", "swift-dependencies", "swift-syntax",
                        "backyard-birds-mac", "backyard-birds-ios", "sqlite-cmake", "cjson", "libtommath", "tinyxml2", "pugixml"])
    }
}
