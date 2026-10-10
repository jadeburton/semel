//
//  ToolDiscoveryTests.swift
//  SemelCoreTests
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-69. Tool descriptors key the build cache, so the version recorded against a tool has
/// to describe the binary that actually runs. `ToolDiscovery` knows no tool by name: it
/// registers what the toolchains' finders locate, under the version those finders read.
/// Fake finders here — what is on this machine is the root package's test to make.
final class ToolDiscoveryTests: SemelCoreTestCase {

    /// A finder that answers from memory; `located` nil is a tool that is not installed.
    private func finder(_ name: String, located: String? = "/usr/bin/true", version: String? = "1.0") -> ToolFinder {
        ToolFinder(name: name, locate: { located }, version: { _ in version })
    }

    private func discover(_ finders: [ToolFinder]) throws -> ToolRunnerRegistry {
        for finder in finders {
            ToolDiscovery.register(finder)
        }
        let registry = ToolRunnerRegistry()
        try ToolDiscovery.registerInstalledTools(into: registry)
        return registry
    }

    private func descriptor(named name: String, in registry: ToolRunnerRegistry) -> ToolDescriptor? {
        registry.registeredDescriptors.first { $0.name == name }
    }

    func test_aToolIsRegisteredUnderTheVersionItsFinderReports() throws {
        let registry = try discover([finder("faketool", version: "Fake tool version 2.1 (build-7)")])

        XCTAssertEqual(try XCTUnwrap(descriptor(named: "faketool", in: registry)).version,
                       "Fake tool version 2.1 (build-7)")
    }

    func test_aToolThatIsNotInstalledIsLeftOut() throws {
        let registry = try discover([finder("missingtool", located: nil)])

        XCTAssertNil(descriptor(named: "missingtool", in: registry))
    }

    /// No version means no identity to key a cache with: better absent than registered
    /// under something made up.
    func test_aToolThatReportsNoVersionIsLeftOut() throws {
        let registry = try discover([finder("mutetool", version: nil)])

        XCTAssertNil(descriptor(named: "mutetool", in: registry))
    }

    /// B-17. Which binary answers to a version on this machine is discovered, never
    /// declared: the descriptor a finder produces carries a fingerprint of the file it
    /// located, and that is what keys the cache apart for two builds of one version.
    func test_theDescriptorFingerprintsTheBinaryTheFinderLocated() throws {
        let registry = try discover([finder("fingerprintedtool", located: "/usr/bin/true")])

        let tool = try XCTUnwrap(descriptor(named: "fingerprintedtool", in: registry))
        XCTAssertEqual(tool.recursiveHash, toolBinaryFingerprint(ofFileAt: "/usr/bin/true"))
        XCTAssertNotNil(tool.recursiveHash)
    }

    /// B-80. What a tool runs beside its binary — a compiler's macro plugins — is folded
    /// into the fingerprint when its finder names it, and a tool with nothing beside it
    /// keeps its binary's fingerprint as it stands.
    func test_theDescriptorFoldsInWhatTheToolRunsBesideItsBinary() throws {
        let registry = try discover([ToolFinder(name: "pluggedtool", locate: { "/usr/bin/true" }, version: { _ in "1.0" },
                                                companionFingerprint: { _ in "plugins" })])

        let tool = try XCTUnwrap(descriptor(named: "pluggedtool", in: registry))
        let binary = try XCTUnwrap(toolBinaryFingerprint(ofFileAt: "/usr/bin/true"))
        XCTAssertEqual(tool.recursiveHash, toolFingerprint(binary: binary, companions: "plugins"))
        XCTAssertNotEqual(tool.recursiveHash, binary)
        XCTAssertNotEqual(toolFingerprint(binary: binary, companions: "other plugins"), tool.recursiveHash)
    }

    func test_theDescriptorNamesTheHost() throws {
        let registry = try discover([finder("hosttool")])

        let tool = try XCTUnwrap(descriptor(named: "hosttool", in: registry))
        XCTAssertEqual(tool.platform, MachineQuery.hostPlatform)
        XCTAssertEqual(tool.architecture, MachineQuery.hostArchitecture)
        XCTAssertEqual(MachineQuery.hostPlatform, "macOS")
        XCTAssertFalse(MachineQuery.hostArchitecture.isEmpty)
    }

    /// Every toolchain's `register()` runs again in every test and in every host that
    /// installs it twice; the second declaration replaces the first rather than doubling it.
    func test_declaringATwiceKeepsTheLatestFinder() throws {
        let registry = try discover([finder("twicetool", version: "first"),
                                     finder("twicetool", version: "second")])

        XCTAssertEqual(registry.registeredDescriptors.filter { $0.name == "twicetool" }.map(\.version),
                       ["second"])
    }

    /// A node pinned to a version that is no longer installed must fail with something the
    /// user can act on — it names what was asked for and what is available.
    func test_aVersionThatIsNoLongerInstalledFailsWithAnActionableMessage() throws {
        let registry = try discover([finder("faketool", version: "Fake tool version 2.1")])

        let stale = ToolDescriptor(name: "faketool", version: "Fake tool version 1.0",
                                   platform: MachineQuery.hostPlatform,
                                   architecture: MachineQuery.hostArchitecture, recursiveHash: nil)

        XCTAssertThrowsError(try registry.tool(descriptor: stale, namespace: "fake.tool")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Fake tool version 1.0"),
                          "should name what the node asked for: \(message)")
            XCTAssertTrue(message.contains("Fake tool version 2.1"),
                          "should name what is installed: \(message)")
        }
    }

    // MARK: - MachineQuery

    func test_aQuestionTheMachineAnswersComesBackTrimmed() {
        XCTAssertEqual(MachineQuery.output(of: "/bin/echo", ["  hello  "]), "hello")
    }

    func test_aQuestionTheMachineCannotAnswerHasNoAnswer() {
        XCTAssertNil(MachineQuery.output(of: "/no/such/executable", []))
        XCTAssertNil(MachineQuery.output(of: "/usr/bin/false", []), "a non-zero exit is no answer")
        XCTAssertNil(MachineQuery.output(of: "/usr/bin/true", []), "silence is no answer")
    }
}
