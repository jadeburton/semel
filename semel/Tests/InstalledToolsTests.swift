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
