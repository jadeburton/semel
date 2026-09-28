//
//  LinkRequirementsTests.swift
//  SemelNodeKitTests
//
//  What a link needs beyond its objects travels as settings from the package converter to
//  the linkers (B-55), so the settings it is written as and read back from must say the
//  same thing, and a union of two products' needs must not depend on which came first.
//

@testable import SemelNodeKit
import XCTest

final class LinkRequirementsTests: XCTestCase {

    func test_roundTripsThroughItsSettings() {
        let requirements = LinkRequirements(frameworks: ["Foundation", "Security"], libraries: ["z"], cxxRuntime: true)

        XCTAssertEqual(requirements.properties, ["frameworks": "Foundation,Security", "libraries": "z", "cxxRuntime": "true"])
        XCTAssertEqual(LinkRequirements(properties: requirements.properties), requirements)
    }

    /// No requirements are no settings, so an empty `SettingsLiteral()` states none.
    func test_noRequirementsAreNoSettings() {
        XCTAssertEqual(LinkRequirements.none.properties, [:])
        XCTAssertEqual(LinkRequirements(properties: [:]), .none)
        XCTAssertTrue(LinkRequirements(properties: ["arguments": "-v"]).isEmpty)
    }

    /// Two products that both link Foundation link it once, and the order is the same
    /// whichever product's list comes first.
    func test_aUnionIsSortedEachOnceAndOrderFree() {
        let first  = LinkRequirements(frameworks: ["Security", "Foundation"], libraries: ["z"], cxxRuntime: false)
        let second = LinkRequirements(frameworks: ["Foundation", "AppKit"], libraries: ["sqlite3", "z"], cxxRuntime: true)

        let union = first.union(second)
        XCTAssertEqual(union, second.union(first))
        XCTAssertEqual(union.frameworks, ["AppKit", "Foundation", "Security"])
        XCTAssertEqual(union.libraries, ["sqlite3", "z"])
        XCTAssertTrue(union.cxxRuntime)
    }

    func test_passesEachFrameworkThenEachLibrary() {
        let requirements = LinkRequirements(frameworks: ["Foundation"], libraries: ["z", "c++abi"], cxxRuntime: true)

        XCTAssertEqual(requirements.frameworkAndLibraryArguments, ["-framework", "Foundation", "-lc++abi", "-lz"])
    }
}
