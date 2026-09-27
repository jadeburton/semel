//
//  SDKCacheKeyTests.swift
//  SemelCLITests
//
//  The only target that sees the engine's cache-key assembly and the Swift tools at once.
//

@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-47, the wide half, end to end: the SDK fingerprint the Swift tools contribute through
/// `cacheKeyMaterial` changes the key the engine computes for them — and only for them.
final class SDKCacheKeyTests: XCTestCase {

    private var savedProvider: ((String) -> String?)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedProvider = sdkFingerprintProvider
        DataObjectStore.shared = DataObjectStore(storeRoot: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true))
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        try SemelSwift.register()
    }

    override func tearDown() {
        sdkFingerprintProvider = savedProvider
        BuildEngine.shared = nil
        super.tearDown()
    }

    /// One dummy wire on every port the node declares, so the key can be built without
    /// knowing the node's port names — the subject is the material, not the inputs.
    private func input<N: Node>(for type: N.Type) throws -> ProcessInput {
        var values: [String: [String: NodeValue]] = [:]
        for port in type.descriptor.staticInputPorts + type.descriptor.dynamicInputPorts {
            values[port] = ["wire": .value(try "content".intern())]
        }
        return ProcessInput(inputValues: values)
    }

    private func key<N: Node>(of type: N.Type, spec: String) throws -> String {
        let (record, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        let node = try type.init(thisNode: record)
        return try XCTUnwrap(node.buildCacheKeyFromAllInputs(input: try input(for: type)))
    }

    func test_theSwiftCompilersKeyChangesWithTheSDKFingerprint() throws {
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: SwiftCompiler.self, spec: "SwiftCompiler()")

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: SwiftCompiler.self, spec: "SwiftCompiler()")

        sdkFingerprintProvider = { _ in "sdk-one" }
        let oneAgain = try key(of: SwiftCompiler.self, spec: "SwiftCompiler()")

        XCTAssertNotEqual(one, two, "a different SDK behind the same declared version is a different build")
        XCTAssertEqual(one, oneAgain)
    }

    func test_theSwiftLinkersKeyChangesWithTheSDKFingerprint() throws {
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: SwiftLinker.self, spec: "SwiftLinker()")

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: SwiftLinker.self, spec: "SwiftLinker()")

        XCTAssertNotEqual(one, two)
    }

    /// A node that never touches the SDK is unaffected: the fingerprint is the Swift
    /// tools' material, not a global salt.
    func test_aNodeThatDoesNotReadTheSDKIsUnaffected() throws {
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: ConfigFilter.self, spec: "ConfigFilter(prefix: 'x')")

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: ConfigFilter.self, spec: "ConfigFilter(prefix: 'x')")

        XCTAssertEqual(one, two)
    }
}
