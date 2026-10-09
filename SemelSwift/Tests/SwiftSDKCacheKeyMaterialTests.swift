//
//  SwiftSDKCacheKeyMaterialTests.swift
//  SemelSwiftTests
//

@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-47. The Swift compiler and linker fold the fingerprint of the SDK behind `-sdk` into
/// their cache key. The fingerprint itself is SemelNodeKit's and pinned there; these pin
/// what the Swift tools contribute, with a stand-in fingerprint.
final class SwiftSDKCacheKeyMaterialTests: SemelSwiftTestCase {

    private var savedProvider: ((String) -> String?)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedProvider = sdkFingerprintProvider
    }

    override func tearDown() {
        sdkFingerprintProvider = savedProvider
        super.tearDown()
    }

    /// A process input carrying only a configuration, which is all the material reads.
    private func input(configuration: String) throws -> ProcessInput {
        ProcessInput(inputValues: [SwiftCompiler.configuration: ["config": .value(try configuration.intern())]])
    }

    /// Both nodes that pass `-sdk` contribute the fingerprint, and nothing else about their
    /// key is involved here — the material is the same string for both. The SDK name is
    /// part of it, so two SDKs that happened to fingerprint alike would still not share.
    func test_theSwiftCompilerAndLinkerContributeTheFingerprintAsCacheKeyMaterial() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))
        let linker   = try SwiftLinker(thisNode: NodeRecord(id: 2, kind: SwiftLinker.kind))

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: "")), "sdk=macosx:0123abcd")
        XCTAssertEqual(try linker.cacheKeyMaterial(input: try input(configuration: "")),   "sdk=macosx:0123abcd")
    }

    /// The fingerprint is of the SDK the configuration names, not always macOS's: the
    /// tree at the path xcrun gives for that name.
    func test_theMaterialIsForTheConfiguredSDK() throws {
        sdkFingerprintProvider = { path in "fp-of-\(path)" }
        let path = try XCTUnwrap(resolveSDKPath(sdk: "iphonesimulator"), "this machine has no iOS simulator SDK")

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: "sdk=iphonesimulator")),
                       "sdk=iphonesimulator:fp-of-\(path)")
    }

    /// B-17. The two things a Swift tool reads outside its inputs reach the key together,
    /// each on its own line: the SDK behind `-sdk`, and the binary behind the tool version
    /// the configuration names.
    func test_theSDKAndTheToolBinaryBothReachTheKey() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }
        ToolRunnerRegistry.instance.registerTool(
            descriptor: .init(name: "swiftc", version: "1.0", platform: "macOS", architecture: "arm64",
                              recursiveHash: "fingerprint-of-the-frontend"),
            toolExecutor: RecordingToolRunner())

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))
        let configuration = ["toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=swiftc",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=1.0"].joined(separator: "\n")

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: configuration)),
                       "sdk=macosx:0123abcd\ntool=swiftc:fingerprint-of-the-frontend")
    }

    /// A configuration naming a version this machine does not have contributes no
    /// fingerprint: the node fails when it is processed, naming what is installed.
    func test_aToolVersionThatIsNotInstalledContributesNothing() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))
        let configuration = ["toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=swiftc",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=1.0"].joined(separator: "\n")

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: configuration)),
                       "sdk=macosx:0123abcd")
    }

    /// With no SDK on the machine there is nothing to fingerprint and nothing to add; the
    /// compile fails on its own for want of an SDK.
    func test_noSDKMeansNoMaterial() throws {
        sdkFingerprintProvider = { _ in nil }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))

        XCTAssertNil(try compiler.cacheKeyMaterial(input: try input(configuration: "")))
    }

    /// The compiler and linker declare the fingerprint as a machine setting, so a machine
    /// file's writer puts it beside the SDK's name and identity and a changed SDK changes
    /// the file (B-47).
    func test_theSwiftNamespacesDeclareTheFingerprintAsAMachineSetting() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }

        for namespace in [SwiftCompilerConfiguration.settingNamespace, SwiftLinkerConfiguration.settingNamespace] {
            let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: namespace))
            XCTAssertTrue(entry.machineSettingKeys.contains(sdkFingerprintMachineSettingKey))
            XCTAssertEqual(entry.machineSettings(.macos)[sdkFingerprintMachineSettingKey], "0123abcd")
        }
    }
}
