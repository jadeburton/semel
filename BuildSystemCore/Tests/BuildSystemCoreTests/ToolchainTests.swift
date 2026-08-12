//
//  ToolchainTests.swift
//  build_system_tests
//

@testable import BuildSystemCore
import XCTest

/// Tool descriptors key the build cache, so the version recorded against a tool has to
/// describe the binary that actually runs.  `Toolchain` reads both from the machine.
final class ToolchainTests: BuildSystemTestCase {

    // MARK: - Version parsing

    func test_parseVersion_clang() {
        let output = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.3.0"
        XCTAssertEqual(Toolchain.parseVersion(from: output), "Apple clang version 21.0.0")
    }

    // swiftc leads with the driver version, so the interesting part is mid-line.
    func test_parseVersion_swiftc() {
        let output = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
        XCTAssertEqual(Toolchain.parseVersion(from: output), "Apple Swift version 6.3.3")
    }

    // The registered descriptors carry a trailing build identifier; comparing drift means
    // reducing both sides to the same canonical form.
    func test_parseVersion_registeredDescriptorForm() {
        XCTAssertEqual(Toolchain.parseVersion(from: "Apple clang version 17.0.0 (clang-1700.6.3.2)"),
                       "Apple clang version 17.0.0")
        XCTAssertEqual(Toolchain.parseVersion(from: "Apple Swift version 6.2.3"),
                       "Apple Swift version 6.2.3")
    }

    func test_parseVersion_unrecognisedOutput() {
        XCTAssertNil(Toolchain.parseVersion(from: "some tool that reports nothing useful"))
    }

    // MARK: - Discovery

    func test_findLocatesAnExecutableForAToolInTheActiveToolchain() throws {
        let path = try XCTUnwrap(Toolchain.find("clang"), "clang must be discoverable via xcrun")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                      "\(path) must be an executable")
    }

    func test_findReturnsNilForAToolThatDoesNotExist() {
        XCTAssertNil(Toolchain.find("definitely-not-a-real-tool-name"))
    }

    func test_versionOfDiscoveredToolIsReadable() throws {
        let path = try XCTUnwrap(Toolchain.find("clang"))
        let version = try XCTUnwrap(Toolchain.version(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("Apple clang version"), "got \(version)")
    }
}
