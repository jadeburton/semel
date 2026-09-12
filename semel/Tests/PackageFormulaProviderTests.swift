//
//  PackageFormulaProviderTests.swift
//  SemelCLITests
//
//  The only target that sees the Swift toolchain's provider and the engine's graph at once.
//

@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-10, end to end at the seam: the spec the Swift toolchain hands a ProjectBuilder for a
/// `package <.>` statement must parse and build the reader-and-converter chain the engine
/// will run. A spec string that only looks right would fail on the first real formula.
final class PackageFormulaProviderTests: XCTestCase {

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

    func test_theProvidersSpecBuildsAConverterOverThePackageManifest() throws {
        let provider = try XCTUnwrap(ProjectDiscovery.packageFormulaProviders.first, "SemelSwift registers one")
        let spec = provider.formulaSpec(forPackageFolder: "input:/repo/pkg")

        let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        XCTAssertEqual(node.kind, SwiftFormulaConverter.kind)
        let readers = try BuildEngine.shared.database.node.select(kind: SwiftPackageReader.kind)
        XCTAssertEqual(readers.count, 1, "the converter is fed by one reader over Package.swift")
    }

    /// The same statement twice is the same converter: the second formula that names a
    /// package shares its nodes rather than reading the manifest twice.
    func test_theSameFolderResolvesToTheSameNode() throws {
        let provider = try XCTUnwrap(ProjectDiscovery.packageFormulaProviders.first)
        let spec = provider.formulaSpec(forPackageFolder: "input:/repo/pkg")

        let (first, _)  = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        let (second, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()

        XCTAssertEqual(first.id, second.id)
    }
}
