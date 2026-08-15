//
//  ToolchainTests.swift
//  build_system_tests
//

@testable import BuildSystemCore
import XCTest
import SemelNodeKit

/// Tool descriptors key the build cache, so the version recorded against a tool has to
/// describe the binary that actually runs.  `Toolchain` reads both from the machine.
final class ToolchainTests: BuildSystemTestCase {

    // MARK: - Version parsing

    // The build identifier is part of the compiler's identity — two clangs with the same
    // marketing version and different build ids are different binaries — so it stays in
    // the string that keys the cache.
    func test_parseVersion_clangKeepsTheBuildIdentifier() {
        let output = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.3.0"
        XCTAssertEqual(Toolchain.parseVersion(from: output),
                       "Apple clang version 21.0.0 (clang-2100.1.1.101)")
    }

    // swiftc leads with its driver version, which is noise; the tool's own version is
    // mid-line and carries the swiftlang build id.
    func test_parseVersion_swiftcSkipsTheDriverVersion() {
        let output = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
        XCTAssertEqual(Toolchain.parseVersion(from: output),
                       "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)")
    }

    func test_parseVersion_withoutABuildIdentifier() {
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

    // MARK: - DefaultTools

    /// The descriptor has to describe the binary that will actually run, or the cache is
    /// keyed to a compiler that is not the one producing the output.
    func test_toolsAreRegisteredUnderTheVersionTheyActuallyReport() throws {
        let registry = ToolExecutorRegistry()
        try DefaultTools.setup(toolExecutorRegistry: registry)

        let clangPath = try XCTUnwrap(Toolchain.find("clang"))
        let installedVersion = try XCTUnwrap(Toolchain.version(ofToolAt: clangPath))

        let clang = try XCTUnwrap(registry.registeredDescriptors.first { $0.name == "clang" },
                                  "clang should be registered on a machine that has it")
        XCTAssertEqual(clang.version, installedVersion)
    }

    func test_setupRegistersEveryToolItCanFind() throws {
        let registry = ToolExecutorRegistry()
        try DefaultTools.setup(toolExecutorRegistry: registry)

        XCTAssertEqual(Set(registry.registeredDescriptors.map(\.name)), ["clang", "swiftc", "swift"])
    }

    /// A node pinned to a version that is no longer installed must fail with something the
    /// user can act on — it names what was asked for and what is available.
    func test_aVersionThatIsNoLongerInstalledFailsWithAnActionableMessage() throws {
        let registry = ToolExecutorRegistry()
        try DefaultTools.setup(toolExecutorRegistry: registry)

        let stale = ToolDescriptor(name: "clang", version: "Apple clang version 1.0.0",
                                   platform: "macOS", architecture: "arm64", recursiveHash: nil)

        XCTAssertThrowsError(try registry.tool(descriptor: stale)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Apple clang version 1.0.0"),
                          "should name what the node asked for: \(message)")
            XCTAssertTrue(message.contains("Apple clang version"),
                          "should name what is installed: \(message)")
        }
    }
}
