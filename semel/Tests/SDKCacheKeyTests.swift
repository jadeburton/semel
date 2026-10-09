//
//  SDKCacheKeyTests.swift
//  SemelCLITests
//
//  The only target that sees the engine's cache-key assembly and the toolchains at once.
//

@testable import SemelClang
@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-47 end to end: the SDK fingerprint the Swift and clang tools contribute through
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
        try SemelClang.register()
    }

    override func tearDown() {
        sdkFingerprintProvider = savedProvider
        BuildEngine.shared = nil
        super.tearDown()
    }

    /// One dummy wire on every port the node declares, so the key can be built without
    /// knowing the node's port names — the subject is the material, not the inputs. The
    /// configuration, which the material reads, can be given.
    private func input<N: Node>(for type: N.Type, configuration: String) throws -> ProcessInput {
        var values: [String: [String: NodeValue]] = [:]
        for port in type.descriptor.staticInputPorts + type.descriptor.dynamicInputPorts {
            values[port] = ["wire": .value(try (port == "configuration" ? configuration : "content").intern())]
        }
        return ProcessInput(inputValues: values)
    }

    private func key<N: Node>(of type: N.Type, spec: String, configuration: String = "") throws -> String {
        let (record, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        let node = try type.init(thisNode: record)
        return try XCTUnwrap(node.buildCacheKeyFromAllInputs(input: try input(for: type, configuration: configuration)))
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

    /// The clang tools name the SDK by path, `sdkPath`, and key on the tree behind it.
    func test_theClangPreprocessorsKeyChangesWithTheSDKFingerprint() throws {
        try assertKeyFollowsTheFingerprint(of: ClangPreprocessor.self, spec: "ClangPreprocessor()")
    }

    func test_theClangCompilersKeyChangesWithTheSDKFingerprint() throws {
        try assertKeyFollowsTheFingerprint(of: ClangCompiler.self, spec: "ClangCompiler()")
    }

    func test_theClangLinkersKeyChangesWithTheSDKFingerprint() throws {
        try assertKeyFollowsTheFingerprint(of: ClangLinker.self, spec: "ClangLinker()")
    }

    private func assertKeyFollowsTheFingerprint<N: Node>(of type: N.Type, spec: String,
                                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let configuration = "sdkPath=/SDKs/MacOSX.sdk"
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: type, spec: spec, configuration: configuration)

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: type, spec: spec, configuration: configuration)

        sdkFingerprintProvider = { _ in "sdk-one" }
        let oneAgain = try key(of: type, spec: spec, configuration: configuration)

        XCTAssertNotEqual(one, two, "a different SDK behind the same path is a different build", file: file, line: line)
        XCTAssertEqual(one, oneAgain, file: file, line: line)
    }

    /// The archiver takes objects and reads no SDK: its key does not move.
    func test_theClangArchiversKeyIsUnaffected() throws {
        let configuration = "sdkPath=/SDKs/MacOSX.sdk"
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: ClangArchiver.self, spec: "ClangArchiver()", configuration: configuration)

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: ClangArchiver.self, spec: "ClangArchiver()", configuration: configuration)

        XCTAssertEqual(one, two)
    }

    /// A node that never touches the SDK is unaffected: the fingerprint is the SDK-reading
    /// tools' material, not a global salt.
    func test_aNodeThatDoesNotReadTheSDKIsUnaffected() throws {
        sdkFingerprintProvider = { _ in "sdk-one" }
        let one = try key(of: ConfigFilter.self, spec: "ConfigFilter(prefix: 'x')")

        sdkFingerprintProvider = { _ in "sdk-two" }
        let two = try key(of: ConfigFilter.self, spec: "ConfigFilter(prefix: 'x')")

        XCTAssertEqual(one, two)
    }
}
