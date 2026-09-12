//
//  PackageIncludeTests.swift
//  SemelCLITests
//
//  The only target that sees the Swift toolchain's converter and the engine's graph at once.
//

@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-10, end to end at the seam: what a formula writes for a Swift package —
/// `include SwiftFormulaConverter(path: <.>).formula` — must parse into a converter the
/// engine can run, and that converter must wire its own reader and folder manifest from
/// the path. A spec that only looks right would fail on the first real formula.
final class PackageIncludeTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true))
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        try SemelSwift.register()
    }

    override func tearDown() {
        BuildEngine.shared = nil
        super.tearDown()
    }

    private let includeSpec = "SwiftFormulaConverter(path: 'input:/repo/pkg').formula"

    func test_theIncludedConverterParsesAndWiresItsOwnReader() throws {
        let (record, _) = try GraphSpecNode.parse(includeSpec).findOrCreateMatchingNode()
        XCTAssertEqual(record.kind, SwiftFormulaConverter.kind)

        // First pass, nothing wired: the converter asks for its folder manifest and reader.
        let node   = try record.makeNode()
        let output = try node.process(input: ProcessInput(inputValues: [:]))
        try node.writeToOutputs(output: output)

        let readers = try BuildEngine.shared.database.node.select(kind: SwiftPackageReader.kind)
        XCTAssertEqual(readers.count, 1, "one reader over input:/repo/pkg/Package.swift")
        let folders = try BuildEngine.shared.database.node.select(kind: Folder.kind)
            .filter { $0.properties["path"] == "input:/repo/pkg" }
        XCTAssertEqual(folders.count, 1, "one Folder node for the package folder")
    }

    /// The same include twice is the same converter: a second formula that names the
    /// package shares its nodes rather than reading the manifest twice.
    func test_theSamePathResolvesToTheSameNode() throws {
        let (first, _)  = try GraphSpecNode.parse(includeSpec).findOrCreateMatchingNode()
        let (second, _) = try GraphSpecNode.parse(includeSpec).findOrCreateMatchingNode()

        XCTAssertEqual(first.id, second.id)
    }
}
