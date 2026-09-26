// ToolNamespaceRendererTests.swift
// SemelProtocolTests
//
// B-109. The machine file both writers produce: pinned to one version, headed, and
// honest about a tool that is not there.

import SemelProtocol
import XCTest

final class ToolNamespaceRendererTests: XCTestCase {

    private func descriptor(version: String, settings: [String: String] = [:]) -> ToolDescriptorRecord {
        ToolDescriptorRecord(name: "clang", version: version, platform: "macOS", architecture: "arm64",
                             machineSettings: settings)
    }

    func test_theListingShowsEveryInstalledVersionAndTheFilePinsTheNewest() {
        let namespace = ToolNamespaceRecord(namespace: "clang.linker", toolName: "clang",
                                            descriptors: [descriptor(version: "16.0.0"), descriptor(version: "17.0.0")])

        let listing = ToolNamespaceRenderer.text(for: [namespace])
        XCTAssertTrue(listing.contains("clang.linker.toolDescriptor.version=16.0.0"), listing)
        XCTAssertTrue(listing.contains("clang.linker.toolDescriptor.version=17.0.0"), listing)

        let file = ToolNamespaceRenderer.machineFile(writtenBy: "a test", platformName: "macos", namespaces: [namespace])
        XCTAssertTrue(file.hasPrefix("// Written by a test for --platform macos"), file)
        XCTAssertFalse(file.contains("version=16.0.0"), "a file names one version: \(file)")
        XCTAssertTrue(file.contains("clang.linker.toolDescriptor.version=17.0.0"), file)
        XCTAssertTrue(file.hasSuffix("\n"), "a file ends in a newline")
    }

    func test_machineSettingsFollowTheDescriptorInKeyOrder() {
        let namespace = ToolNamespaceRecord(namespace: "clang.linker", toolName: "clang",
                                            descriptors: [descriptor(version: "17.0.0",
                                                                     settings: ["sdkPath": "/SDKs/MacOSX.sdk", "b": "2"])])

        let lines = ToolNamespaceRenderer.text(for: [namespace]).components(separatedBy: "\n")

        XCTAssertEqual(lines.suffix(2), ["clang.linker.b=2", "clang.linker.sdkPath=/SDKs/MacOSX.sdk"])
    }

    func test_aNamespaceWhoseToolIsMissingIsAComment() {
        let namespace = ToolNamespaceRecord(namespace: "clang.linker", toolName: "clang", descriptors: [])

        let file = ToolNamespaceRenderer.machineFile(writtenBy: "a test", platformName: "macos", namespaces: [namespace])

        XCTAssertTrue(file.contains("// clang.linker: no clang is installed on this machine"), file)
        XCTAssertFalse(file.contains("clang.linker.toolDescriptor"), file)
    }
}
