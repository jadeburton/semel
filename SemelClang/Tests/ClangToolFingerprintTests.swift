//
//  ClangToolFingerprintTests.swift
//  SemelClangTests
//
//  B-17. Every node here runs a binary discovery found, and a configuration can only name
//  that binary's version. Each declares the fingerprint of the binary as cache-key
//  material, so two clangs calling themselves one version do not share an entry — and a
//  node type added without that declaration is what this notices.
//

@testable import SemelClang
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ClangToolFingerprintTests: SemelClangTestCase {

    private let fingerprint = "fingerprint-of-the-clang-binary"

    override func setUpWithError() throws {
        try super.setUpWithError()
        ToolRunnerRegistry.instance.registerTool(
            descriptor: .init(name: "clang", version: "test-clang", platform: "macOS",
                              architecture: "arm64", recursiveHash: fingerprint),
            toolExecutor: RecordingToolRunner())
    }

    private func input(port: String) throws -> ProcessInput {
        let configuration = ["toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=clang",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=test-clang"].joined(separator: "\n")
        return ProcessInput(inputValues: [port: ["config": .value(try configuration.intern())]])
    }

    func test_thePreprocessorDeclaresTheBinaryBehindItsVersion() throws {
        let node = try ClangPreprocessor(thisNode: NodeRecord(id: 1, kind: ClangPreprocessor.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: ClangPreprocessor.configuration)),
                       "tool=clang:\(fingerprint)")
    }

    func test_theCompilerDeclaresTheBinaryBehindItsVersion() throws {
        let node = try ClangCompiler(thisNode: NodeRecord(id: 2, kind: ClangCompiler.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: ClangCompiler.configuration)),
                       "tool=clang:\(fingerprint)")
    }

    func test_theLinkerDeclaresTheBinaryBehindItsVersion() throws {
        let node = try ClangLinker(thisNode: NodeRecord(id: 3, kind: ClangLinker.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: ClangLinker.configuration)),
                       "tool=clang:\(fingerprint)")
    }
}
