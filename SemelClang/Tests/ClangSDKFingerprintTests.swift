//
//  ClangSDKFingerprintTests.swift
//  SemelClangTests
//
//  B-47. The preprocessor, compiler and linker read the SDK at `sdkPath`, so each folds the
//  fingerprint of that tree into its key beside the binary's, and each declares it as a
//  machine setting for a machine file's writer to put beside the path. That the material
//  moves the key the engine computes is the root package's `SDKCacheKeyTests`.
//

@testable import SemelClang
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ClangSDKFingerprintTests: SemelClangTestCase {

    private var savedProvider: ((String) -> String?)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedProvider = sdkFingerprintProvider
        ToolRunnerRegistry.instance.registerTool(
            descriptor: .init(name: "clang", version: "test-clang", platform: "macOS",
                              architecture: "arm64", recursiveHash: "fingerprint-of-the-clang-binary"),
            toolExecutor: RecordingToolRunner())
    }

    override func tearDown() {
        sdkFingerprintProvider = savedProvider
        super.tearDown()
    }

    private func input(port: String, sdkPath: String?) throws -> ProcessInput {
        let configuration = ["toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=clang",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=test-clang"] + (sdkPath.map { ["sdkPath=\($0)"] } ?? [])
        return ProcessInput(inputValues: [port: ["config": .value(try configuration.joined(separator: "\n").intern())]])
    }

    /// Each tool, built bare, with the port its configuration arrives on.
    private func tools() throws -> [(name: String, node: any Node, port: String)] {
        [("ClangPreprocessor", try ClangPreprocessor(thisNode: NodeRecord(id: 1, kind: ClangPreprocessor.kind)),
          ClangPreprocessor.configuration),
         ("ClangCompiler", try ClangCompiler(thisNode: NodeRecord(id: 2, kind: ClangCompiler.kind)),
          ClangCompiler.configuration),
         ("ClangLinker", try ClangLinker(thisNode: NodeRecord(id: 3, kind: ClangLinker.kind)),
          ClangLinker.configuration)]
    }

    func test_eachToolDeclaresTheSDKBehindItsPathAndTheBinary() throws {
        sdkFingerprintProvider = { path in path == "/SDKs/MacOSX26.5.sdk" ? "0123abcd" : nil }

        for tool in try tools() {
            XCTAssertEqual(try tool.node.cacheKeyMaterial(input: try input(port: tool.port, sdkPath: "/SDKs/MacOSX26.5.sdk")),
                           "sdk=MacOSX26.5.sdk:0123abcd\ntool=clang:fingerprint-of-the-clang-binary", tool.name)
        }
    }

    func test_eachToolsMaterialChangesWithTheFingerprint() throws {
        for tool in try tools() {
            sdkFingerprintProvider = { _ in "sdk-one" }
            let one = try tool.node.cacheKeyMaterial(input: try input(port: tool.port, sdkPath: "/SDKs/MacOSX.sdk"))
            sdkFingerprintProvider = { _ in "sdk-two" }
            let two = try tool.node.cacheKeyMaterial(input: try input(port: tool.port, sdkPath: "/SDKs/MacOSX.sdk"))

            XCTAssertNotEqual(one, two, "\(tool.name): a different SDK behind one path is a different build")
        }
    }

    /// A build that configures no SDK keys on the binary alone.
    func test_noSDKPathMeansNoSDKMaterial() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }

        for tool in try tools() {
            XCTAssertEqual(try tool.node.cacheKeyMaterial(input: try input(port: tool.port, sdkPath: nil)),
                           "tool=clang:fingerprint-of-the-clang-binary", tool.name)
        }
    }

    func test_theSDKReadingNamespacesDeclareTheFingerprintAsAMachineSetting() throws {
        for namespace in [ClangPreprocessorConfiguration.settingNamespace,
                          ClangCompilerConfiguration.settingNamespace,
                          ClangLinkerConfiguration.settingNamespace] {
            let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: namespace))
            XCTAssertEqual(entry.machineSettingKeys, ["sdkPath", sdkFingerprintMachineSettingKey], namespace)
        }
        let archiver = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: ClangArchiverConfiguration.settingNamespace))
        XCTAssertTrue(archiver.machineSettingKeys.isEmpty, "the archiver takes objects and reads no SDK")
    }
}
