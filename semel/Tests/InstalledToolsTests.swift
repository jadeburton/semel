//
//  InstalledToolsTests.swift
//  SemelCLITests
//
//  The only target that sees every toolchain at once: what a host that installs all three
//  ends up with, on this machine.
//

import SemelApple
import SemelClang
import SemelNodeKit
import SemelSwift
import XCTest

/// B-69. The engine knows no tool by name; the five a build needs are what the three
/// toolchains declare, located and versioned by each. This is what `semelserv` and
/// `semel-swift prepare` register on the machine they run on.
final class InstalledToolsTests: XCTestCase {

    private var registry: ToolRunnerRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SemelSwift.register()
        try SemelClang.register()
        try SemelApple.register()
        registry = ToolRunnerRegistry()
        try ToolDiscovery.registerInstalledTools(into: registry)
    }

    private func version(of name: String) throws -> String {
        try XCTUnwrap(registry.registeredDescriptors.first { $0.name == name },
                      "\(name) should be registered on a machine that has it").version
    }

    func test_everyToolTheToolchainsDeclareIsFoundOnThisMachine() {
        XCTAssertEqual(Set(registry.registeredDescriptors.map(\.name)),
                       ["clang", "swiftc", "swift", "actool", "xcstringstool"])
    }

    /// B-17. Every tool found here is registered under a fingerprint of the binary behind
    /// it, so a node's cache key can tell two builds of one version apart. `swiftc` and
    /// `swift` are two names for one binary in an Apple toolchain and fingerprint alike;
    /// the tool's name is in the key material beside the fingerprint, which is what keeps
    /// their nodes apart.
    func test_everyInstalledToolIsRegisteredUnderAFingerprintOfItsBinary() {
        XCTAssertEqual(registry.registeredDescriptors.filter { $0.recursiveHash == nil }.map(\.name), [],
                       "a tool the finder located has a binary to fingerprint")
        XCTAssertNotEqual(registry.registeredDescriptors.first { $0.name == "clang" }?.recursiveHash,
                          registry.registeredDescriptors.first { $0.name == "actool" }?.recursiveHash,
                          "two different binaries, two different fingerprints")
    }

    /// The identity a `semel.config` spells out is still the whole of what selects a tool:
    /// a config file written before the fingerprint existed names four fields and must go
    /// on finding the tool it always found.
    func test_aConfigurationThatNamesNoFingerprintStillSelectsItsTool() throws {
        let installed = try XCTUnwrap(registry.registeredDescriptors.first { $0.name == "swiftc" })
        let asAConfigFileSpellsIt = ToolDescriptor(name: installed.name,
                                                   version: installed.version,
                                                   platform: installed.platform,
                                                   architecture: installed.architecture,
                                                   recursiveHash: nil)

        XCTAssertNoThrow(try registry.tool(descriptor: asAConfigFileSpellsIt))
    }

    /// Each version names a build, since the descriptor keys the cache and two builds of
    /// one marketing version are different binaries.
    func test_everyToolIsRegisteredUnderAVersionThatNamesABuild() throws {
        XCTAssertTrue(try version(of: "clang").hasPrefix("Apple clang version "))
        XCTAssertTrue(try version(of: "swiftc").hasPrefix("Apple Swift version "))
        XCTAssertTrue(try version(of: "swift").hasPrefix("Apple Swift version "))
        XCTAssertTrue(try version(of: "actool").hasPrefix("Apple actool version "))
        XCTAssertTrue(try version(of: "xcstringstool").hasPrefix("Xcode "))
        for descriptor in registry.registeredDescriptors {
            XCTAssertTrue(descriptor.version.contains("("), "\(descriptor.name): \(descriptor.version)")
            XCTAssertEqual(descriptor.platform, "macOS")
        }
    }
}
