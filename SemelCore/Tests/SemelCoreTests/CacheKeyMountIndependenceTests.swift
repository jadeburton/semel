//
//  CacheKeyMountIndependenceTests.swift
//  SemelCoreTests
//
//  A cache key names every input by its path relative to the project root and by nothing
//  above it (B-49). Two developers point `base` at different folders and get the same key;
//  two files at different project-relative paths never do (`Cache.swift`'s lesson).
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

    /// The root is not a cache input: two nodes that differ only in where their project
    /// sits agree on every key. Without this the property would put back the very string
    /// the wire names had stripped.
    func test_theProjectRootPropertyIsNotPartOfTheKey() throws {
        let one = try node(projectRoot: "input:/p").buildCacheKeyFromAllInputs(input: try input(source: "input:/p/x.c"))
        let two = try node(projectRoot: "input:/q").buildCacheKeyFromAllInputs(input: try input(source: "input:/q/x.c"))

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
}
