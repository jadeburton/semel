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
}
