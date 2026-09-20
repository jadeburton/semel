//
//  CacheKeyMountIndependenceTests.swift
//  SemelCoreTests
//
//  B-49's intended invariant: a cache key names every input by its path relative to the
//  project root and by nothing above it, so two developers who point `base` at different
//  folders get the same key. Not yet applied — the tests for that shape are skipped until
//  the sandbox materialises inputs at the project-relative path (part 3). What is live is
//  the plumbing: `projectRelative(wire:)` itself, and the exclusion that keeps
//  `projectRoot` out of a node's own key (`Cache.swift`'s lesson still holds: keying on
//  values alone once returned another file's build).
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CacheKeyMountIndependenceTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private func node(projectRoot: String?) throws -> SampleTool {
        var spec = "SampleTool()"
        if let projectRoot {
            spec = "SampleTool(projectRoot: '\(projectRoot)')"
        }
        let (record, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        return try SampleTool(thisNode: record)
    }

    private func input(source: String) throws -> ProcessInput {
        let configuration = ["toolDescriptor.name=sample", "toolDescriptor.version=1",
                             "toolDescriptor.platform=macOS", "toolDescriptor.architecture=arm64"].joined(separator: "\n")
        return ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try configuration.intern())],
            SampleTool.input: [source: .value(try "int main(){}".intern())],
        ])
    }

    func test_theSameProjectAtTwoPlacesUnderInputHasOneKey() throws {
        throw XCTSkip("B-49 part 3: wire names enter the key whole until the sandbox materialises inputs at their project-relative path")

        let shallow = try node(projectRoot: "input:/a/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/a/proj/src/hello.c"))
        let deep = try node(projectRoot: "input:/deeper/b/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/deeper/b/proj/src/hello.c"))

        XCTAssertEqual(shallow, deep)
    }

    func test_twoProjectRelativePathsStillHaveTwoKeys() throws {
        let tool = try node(projectRoot: "input:/a/proj")

        let one = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/a.c"))
        let two = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/b.c"))

        XCTAssertNotEqual(one, two, "the project-relative path stays in the key")
    }

    func test_aWireOutsideTheProjectRootIsKeyedWhole() throws {
        let tool = try node(projectRoot: "input:/a/proj")

        let inside  = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/x.c"))
        let outside = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/elsewhere/x.c"))

        XCTAssertNotEqual(inside, outside)
    }

    /// A wire equal to the root, not merely under it — the target *is* the project's own
    /// folder — strips to the empty remainder rather than keying on the absolute path the
    /// root exists to strip.
    func test_aWireEqualToTheProjectRootKeysAsDot() throws {
        throw XCTSkip("B-49 part 3: wire names enter the key whole until the sandbox materialises inputs at their project-relative path")

        let shallow = try node(projectRoot: "input:/a/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/a/proj"))
        let deep = try node(projectRoot: "input:/deeper/b/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/deeper/b/proj"))

        XCTAssertEqual(shallow, deep)
    }

    func test_aRootWithATrailingSlashStripsTheSameWay() throws {
        throw XCTSkip("B-49 part 3: wire names enter the key whole until the sandbox materialises inputs at their project-relative path")

        let noSlash = try node(projectRoot: "input:/a/proj").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/a/proj/src/x.c"))
        let withSlash = try node(projectRoot: "input:/a/proj/").buildCacheKeyFromAllInputs(
            input: try input(source: "input:/a/proj/src/x.c"))

        XCTAssertEqual(noSlash, withSlash)
    }

    /// The root is excluded from the key by name, not merely by keying on the wire names
    /// alone: two nodes fed the identical wire key still agree when their `projectRoot`
    /// properties differ, because `cacheKeyExcludedProperties` drops the property before
    /// `nodeCacheKey` hashes what remains.
    func test_theProjectRootPropertyIsNotPartOfTheKey() throws {
        let one = try node(projectRoot: "input:/p").buildCacheKeyFromAllInputs(input: try input(source: "input:/p/x.c"))
        let two = try node(projectRoot: "input:/q").buildCacheKeyFromAllInputs(input: try input(source: "input:/p/x.c"))

        XCTAssertEqual(one, two)
    }

    /// A node with no root — every node created before this property existed, and every
    /// node a formula wires by hand — keys exactly as it did.
    func test_aNodeWithoutAProjectRootKeysItsWiresWhole() throws {
        let tool = try node(projectRoot: nil)

        let key = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/a/proj/src/hello.c"))
        let moved = try tool.buildCacheKeyFromAllInputs(input: try input(source: "input:/b/proj/src/hello.c"))

        XCTAssertNotEqual(key, moved)
    }

    // MARK: - projectRelative(wire:) direct

    func test_projectRelativeStripsTheRoot() throws {
        let tool = try node(projectRoot: "input:/a/proj")
        XCTAssertEqual(tool.projectRelative(wire: "input:/a/proj/src/x.c"), "src/x.c")

        let toolWithTrailingSlash = try node(projectRoot: "input:/a/proj/")
        XCTAssertEqual(toolWithTrailingSlash.projectRelative(wire: "input:/a/proj/src/x.c"), "src/x.c")
    }

    func test_projectRelativeKeepsAWireOutsideTheRootWhole() throws {
        let tool = try node(projectRoot: "input:/a/proj")
        XCTAssertEqual(tool.projectRelative(wire: "input:/elsewhere/x.c"), "input:/elsewhere/x.c")
    }

    func test_projectRelativeMapsTheRootItselfToDot() throws {
        let tool = try node(projectRoot: "input:/a/proj")
        XCTAssertEqual(tool.projectRelative(wire: "input:/a/proj"), ".")
    }

    /// Pins `SampleTool.cacheKeyExcludedProperties` and `SampleTool.projectRootProperty`
    /// together, so a rename of one without the other fails here rather than silently
    /// putting the root back into the key.
    func test_theExcludedPropertyNameMatchesTheStampedOne() {
        XCTAssertTrue(SampleTool.cacheKeyExcludedProperties.contains(SampleTool.projectRootProperty))
    }
}
