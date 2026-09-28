//
//  SwiftPackageIncludePluginTests.swift
//  SemelSwiftTests
//
//  B-10 residual 2: what the engine is told builds a pushed `Package.swift`, so it can say
//  so when no formula includes one.
//

@testable import SemelSwift
import SemelNodeKit
import XCTest

final class SwiftPackageIncludePluginTests: SemelSwiftTestCase {

    private let plugin = SwiftPackageIncludePlugin()

    private func manifest(isPinned: Bool = true) -> FolderManifestEntry {
        FolderManifestEntry(name: "Package.swift", isFolder: false, isPinned: isPinned)
    }

    func test_aPushedManifestIsBuiltByTheConverterOfItsFolder() throws {
        let include = try XCTUnwrap(plugin.includeSpec(forEntry: manifest(), inFolder: "input:/Packages/Foo"))

        XCTAssertEqual(include.asString(omitOutputPort: false), "SwiftFormulaConverter(path: 'input:/Packages/Foo').formula")
    }

    /// A vendored dependency is reached through the root's converter, and whatever else a
    /// checkout carries — a dependency no target uses, its own example packages — is not
    /// this tree's to build.
    func test_aManifestAnywhereUnderADependenciesFolderIsNotClaimed() {
        XCTAssertNil(plugin.includeSpec(forEntry: manifest(), inFolder: "input:/Packages/Dependencies/GRDB.swift"))
        XCTAssertNil(plugin.includeSpec(forEntry: manifest(), inFolder: "input:/Packages/Dependencies/GRDB.swift/Demo/App"))
    }

    func test_onlyAPushedManifestIsClaimed() {
        XCTAssertNil(plugin.includeSpec(forEntry: manifest(isPinned: false), inFolder: "input:/Packages/Foo"))
        XCTAssertNil(plugin.includeSpec(forEntry: FolderManifestEntry(name: "Package.resolved", isFolder: false, isPinned: true),
                                        inFolder: "input:/Packages/Foo"))
    }
}
