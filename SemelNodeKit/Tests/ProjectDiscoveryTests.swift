//
//  ProjectDiscoveryTests.swift
//  SemelNodeKitTests
//
//  The registry that lets a package contribute a project kind without the engine knowing
//  it exists.
//

@testable import SemelNodeKit
import XCTest

final class ProjectDiscoveryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProjectDiscovery.removeAll()
    }

    override func tearDown() {
        ProjectDiscovery.removeAll()
        super.tearDown()
    }

    private struct AlphaPlugin: ProjectBuilderPlugin {
        func specString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String? {
            entry.name == "alpha" ? "Alpha" : nil
        }
    }

    private struct ZuluPlugin: ProjectBuilderPlugin {
        func specString(forEntry entry: FolderManifestEntry, inFolder folderPath: String) -> String? {
            entry.name == "zulu" ? "Zulu" : nil
        }
    }

    private func entry(_ name: String) -> FolderManifestEntry {
        .init(name: name, isFolder: false, isPinned: true)
    }

    func test_aRegisteredPluginIsConsulted() {
        ProjectDiscovery.register(AlphaPlugin())

        let claimed = ProjectDiscovery.plugins.compactMap {
            $0.specString(forEntry: entry("alpha"), inFolder: "input:/x")
        }
        XCTAssertEqual(claimed, ["Alpha"])
    }

    func test_anUnclaimedEntryProducesNothing() {
        ProjectDiscovery.register(AlphaPlugin())

        XCTAssertTrue(ProjectDiscovery.plugins.allSatisfy {
            $0.specString(forEntry: entry("something else"), inFolder: "input:/x") == nil
        })
    }

    /// Registration runs again for every test and on every process start, so a registry
    /// that appended would grow without bound and ask the same plugin repeatedly.
    func test_registeringTheSamePluginTwiceDoesNotDuplicateIt() {
        ProjectDiscovery.register(AlphaPlugin())
        ProjectDiscovery.register(AlphaPlugin())

        XCTAssertEqual(ProjectDiscovery.plugins.count, 1)
    }

    /// Discovery takes the *first* plugin that claims an entry, so the order it walks them
    /// in must not vary between processes the way Dictionary iteration does.
    func test_pluginsComeBackInAStableOrder() {
        ProjectDiscovery.register(ZuluPlugin())
        ProjectDiscovery.register(AlphaPlugin())

        let names = ProjectDiscovery.plugins.map { String(describing: type(of: $0)) }
        XCTAssertEqual(names, ["AlphaPlugin", "ZuluPlugin"],
                       "sorted by type name, not by when they happened to register")
    }

    func test_removeAllEmptiesTheRegistry() {
        ProjectDiscovery.register(AlphaPlugin())
        ProjectDiscovery.removeAll()

        XCTAssertTrue(ProjectDiscovery.plugins.isEmpty)
    }
}
