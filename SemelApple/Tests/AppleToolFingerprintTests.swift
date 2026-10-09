//
//  AppleToolFingerprintTests.swift
//  SemelAppleTests
//
//  B-17. Both catalog compilers run a binary discovery found, and a configuration can only
//  name that binary's version. Each declares the fingerprint of the binary as cache-key
//  material, so two toolchains calling themselves one version do not share an entry. These
//  pin what that declaration produces for both; that every node which runs a tool makes one
//  at all is a source scan's job, in SemelCore's `ToolNodeCacheKeyTests`.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class AppleToolFingerprintTests: SemelAppleTestCase {

    private func register(tool name: String, fingerprint: String) {
        ToolRunnerRegistry.instance.registerTool(
            descriptor: .init(name: name, version: "test-\(name)", platform: "macOS",
                              architecture: "arm64", recursiveHash: fingerprint),
            toolExecutor: RecordingToolRunner())
    }

    private func input(port: String, tool name: String) throws -> ProcessInput {
        let configuration = ["toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=\(name)",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=test-\(name)"].joined(separator: "\n")
        return ProcessInput(inputValues: [port: ["config": .value(try configuration.intern())]])
    }

    func test_theAssetCatalogCompilerDeclaresTheBinaryBehindItsVersion() throws {
        register(tool: "actool", fingerprint: "fingerprint-of-actool")
        let node = try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: AssetCatalogCompiler.configuration,
                                                                  tool: "actool")),
                       "tool=actool:fingerprint-of-actool")
    }

    func test_theStringCatalogCompilerDeclaresTheBinaryBehindItsVersion() throws {
        register(tool: "xcstringstool", fingerprint: "fingerprint-of-xcstringstool")
        let node = try StringCatalogCompiler(thisNode: NodeRecord(id: 2, kind: StringCatalogCompiler.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: StringCatalogCompiler.configuration,
                                                                  tool: "xcstringstool")),
                       "tool=xcstringstool:fingerprint-of-xcstringstool")
    }

    /// B-47. ibtool is told the SDK by path, and keys on the tree behind it beside its
    /// binary; the namespace declares the fingerprint as a machine setting beside the path.
    func test_theIBToolCompilerDeclaresTheSDKBehindItsPathAndTheBinary() throws {
        let savedProvider = sdkFingerprintProvider
        defer { sdkFingerprintProvider = savedProvider }
        sdkFingerprintProvider = { path in path == "/SDKs/MacOSX26.5.sdk" ? "0123abcd" : nil }
        register(tool: "ibtool", fingerprint: "fingerprint-of-ibtool")
        let node = try IBToolCompiler(thisNode: NodeRecord(id: 3, kind: IBToolCompiler.kind))
        let configuration = ["sdkPath=/SDKs/MacOSX26.5.sdk",
                             "toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=ibtool",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=test-ibtool"].joined(separator: "\n")
        let input = ProcessInput(inputValues: [IBToolCompiler.configuration: ["config": .value(try configuration.intern())]])

        XCTAssertEqual(try node.cacheKeyMaterial(input: input),
                       "sdk=MacOSX26.5.sdk:0123abcd\ntool=ibtool:fingerprint-of-ibtool")
        let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: IBToolCompilerConfiguration.settingNamespace))
        XCTAssertEqual(entry.machineSettingKeys, ["sdkPath", sdkFingerprintMachineSettingKey])
    }
}
