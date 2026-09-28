// ToolNamespaceRendererTests.swift
// SemelProtocolTests
//
// B-109. The pieces both writers build the machine file from: pinned to one version,
// headed, and honest about a tool that is not there.

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

        let pinned = ToolNamespaceRenderer.text(for: ToolNamespaceRenderer.pinnedToNewest([namespace]))
        XCTAssertFalse(pinned.contains("version=16.0.0"), "a file names one version: \(pinned)")
        XCTAssertTrue(pinned.contains("clang.linker.toolDescriptor.version=17.0.0"), pinned)
    }

    func test_theHeaderNamesTheWriterAndThePlatform() {
        let header = ToolNamespaceRenderer.machineFileHeader(writtenBy: "a test", platformName: "macos")

        XCTAssertTrue(header[0].hasPrefix(ToolNamespaceRenderer.machineFileHeaderOpening), "\(header)")
        XCTAssertTrue(header[0].hasPrefix("// Written by a test for --platform macos"), "\(header)")
        XCTAssertTrue(header.allSatisfy { $0.hasPrefix("// ") }, "every line is a comment: \(header)")
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

        let text = ToolNamespaceRenderer.text(for: ToolNamespaceRenderer.pinnedToNewest([namespace]))

        XCTAssertEqual(text, "// clang.linker: no clang is installed on this machine")
    }
}
