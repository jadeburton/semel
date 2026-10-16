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

    private var savedBuild: String?
    private var savedRuntimes: ((String) -> String?)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedBuild = HostOperatingSystem.build
        HostOperatingSystem.build = "25A100"
        savedRuntimes = SimulatorRuntimes.provider
        SimulatorRuntimes.provider = { family in family == "iOS" ? "com.apple.CoreSimulator.SimRuntime.iOS-26-5@23F77" : nil }
    }

    override func tearDown() {
        HostOperatingSystem.build = savedBuild
        if let savedRuntimes {
            SimulatorRuntimes.provider = savedRuntimes
        }
        super.tearDown()
    }

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
                       "tool=actool:fingerprint-of-actool\nos=25A100")
    }

    func test_theStringCatalogCompilerDeclaresTheBinaryBehindItsVersion() throws {
        register(tool: "xcstringstool", fingerprint: "fingerprint-of-xcstringstool")
        let node = try StringCatalogCompiler(thisNode: NodeRecord(id: 2, kind: StringCatalogCompiler.kind))

        XCTAssertEqual(try node.cacheKeyMaterial(input: try input(port: StringCatalogCompiler.configuration,
                                                                  tool: "xcstringstool")),
                       "tool=xcstringstool:fingerprint-of-xcstringstool\nos=25A100")
    }

    /// B-47. ibtool is told the SDK by path, and keys on the tree behind it beside its
    /// binary; the namespace declares the fingerprint as a machine setting beside the path.
    func test_theIBToolCompilerDeclaresTheSDKBehindItsPathAndTheBinary() throws {
        let savedProvider = sdkFingerprintProvider
        defer { sdkFingerprintProvider = savedProvider }
        sdkFingerprintProvider = { path in path == "/SDKs/MacOSX26.5.sdk" ? "0123abcd" : nil }
        register(tool: "ibtool", fingerprint: "fingerprint-of-ibtool")
        let node = try IBToolCompiler(thisNode: NodeRecord(id: 3, kind: IBToolCompiler.kind))
        let configuration = ["sdkPath=/SDKs/MacOSX26.5.sdk",
                             "toolDescriptor.architecture=arm64",
                             "toolDescriptor.name=ibtool",
                             "toolDescriptor.platform=macOS",
                             "toolDescriptor.version=test-ibtool"].joined(separator: "\n")
        let input = ProcessInput(inputValues: [IBToolCompiler.configuration: ["config": .value(try configuration.intern())]])

        XCTAssertEqual(try node.cacheKeyMaterial(input: input),
                       "sdk=MacOSX26.5.sdk:0123abcd\ntool=ibtool:fingerprint-of-ibtool\nos=25A100")
        let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: IBToolCompilerConfiguration.settingNamespace))
        XCTAssertEqual(entry.machineSettingKeys, ["sdkPath", sdkFingerprintMachineSettingKey, HostOperatingSystem.buildMachineSettingKey,
                                                  SimulatorRuntimes.machineSettingKey])
    }

    // MARK: - The system's build (B-153)

    /// actool, ibtool, momc, xcstringstool and codesign work through the system's frameworks,
    /// which an update of macOS changes under a tool that stays as it was: each node keys on
    /// the system's build, so two machines on two builds share none of their entries.
    func test_everyToolThatWorksThroughTheSystemKeysOnItsBuild() throws {
        let configuration = ["toolDescriptor.architecture=arm64", "toolDescriptor.name=tool",
                             "toolDescriptor.platform=macOS", "toolDescriptor.version=1"].joined(separator: "\n")
        let nodes: [(any Node, String)] = [
            (try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind)), AssetCatalogCompiler.configuration),
            (try StringCatalogCompiler(thisNode: NodeRecord(id: 2, kind: StringCatalogCompiler.kind)), StringCatalogCompiler.configuration),
            (try IBToolCompiler(thisNode: NodeRecord(id: 3, kind: IBToolCompiler.kind)), IBToolCompiler.configuration),
            (try CoreDataModelCompiler(thisNode: NodeRecord(id: 4, kind: CoreDataModelCompiler.kind)), CoreDataModelCompiler.configuration),
            (try CodeSigner(thisNode: NodeRecord(id: 5, kind: CodeSigner.kind)), CodeSigner.configuration),
        ]
        for (node, port) in nodes {
            let input = ProcessInput(inputValues: [port: ["config": .value(try configuration.intern())]])
            HostOperatingSystem.build = "25A100"
            let onOne = try node.cacheKeyMaterial(input: input)
            HostOperatingSystem.build = "25B200"
            let onAnother = try node.cacheKeyMaterial(input: input)

            XCTAssertEqual(onOne, "os=25A100", "\(type(of: node))")
            XCTAssertNotEqual(onOne, onAnother, "\(type(of: node)) keys apart on two builds of the system")
        }
    }

    /// The machine file's half: every one of those namespaces declares the build as a
    /// machine setting and writes it, so an update of the system wakes the nodes reading it.
    func test_everyNamespaceOfAToolThatWorksThroughTheSystemWritesItsBuild() throws {
        for namespace in [AssetCatalogCompilerConfiguration.settingNamespace, StringCatalogCompilerConfiguration.settingNamespace,
                          IBToolCompilerConfiguration.settingNamespace, CoreDataModelCompilerConfiguration.settingNamespace,
                          CodeSignerConfiguration.settingNamespace] {
            let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: namespace))
            XCTAssertTrue(entry.machineSettingKeys.contains(HostOperatingSystem.buildMachineSettingKey), namespace)
            XCTAssertEqual(entry.machineSettings(.macos)[HostOperatingSystem.buildMachineSettingKey], "25A100", namespace)
        }
    }

    /// An iOS catalog and an iOS document compile through the simulator runtime's
    /// frameworks: the runtimes installed for the platform are in the key, and a Mac's
    /// compile, which uses the Mac's own, keys without them.
    func test_anIOSCompileKeysOnTheSimulatorRuntimesInstalled() throws {
        let catalogs = try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind))
        func catalogMaterial(platform: String) throws -> String? {
            try catalogs.cacheKeyMaterial(input: ProcessInput(inputValues: [AssetCatalogCompiler.configuration: [
                "config": .value(try "platform=\(platform)".intern())]]))
        }
        XCTAssertEqual(try catalogMaterial(platform: "iphonesimulator"),
                       "os=25A100\nruntimes=com.apple.CoreSimulator.SimRuntime.iOS-26-5@23F77")
        XCTAssertEqual(try catalogMaterial(platform: "macosx"), "os=25A100")

        let documents = try IBToolCompiler(thisNode: NodeRecord(id: 3, kind: IBToolCompiler.kind))
        let iOSDocument = try documents.cacheKeyMaterial(input: ProcessInput(inputValues: [IBToolCompiler.configuration: [
            "config": .value(try "sdkPath=/SDKs/iPhoneSimulator26.5.sdk".intern())]]))
        XCTAssertTrue(iOSDocument?.hasSuffix("runtimes=com.apple.CoreSimulator.SimRuntime.iOS-26-5@23F77") ?? false,
                      iOSDocument ?? "nil")

        let entry = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: AssetCatalogCompilerConfiguration.settingNamespace))
        XCTAssertEqual(entry.machineSettings(.iosSimulator)[SimulatorRuntimes.machineSettingKey],
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-5@23F77")
        XCTAssertNil(entry.machineSettings(.macos)[SimulatorRuntimes.machineSettingKey])
    }

    /// The `codesign_allocate` codesign runs is keyed by its bytes, as the tool is: the
    /// configuration names it by a path, and two Xcodes installed at one path share it.
    func test_theCodeSignerKeysOnTheBytesOfTheAllocatorItRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-allocator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let allocator = folder.appendingPathComponent("codesign_allocate")
        let node = try CodeSigner(thisNode: NodeRecord(id: 5, kind: CodeSigner.kind))
        let input = ProcessInput(inputValues: [CodeSigner.configuration: [
            "config": .value(try "codesignAllocatePath=\(allocator.path)".intern())]])

        try Data("first allocator".utf8).write(to: allocator)
        let first = try XCTUnwrap(try node.cacheKeyMaterial(input: input))
        let other = folder.appendingPathComponent("other")
        try Data("second allocator".utf8).write(to: other)
        let second = try XCTUnwrap(try node.cacheKeyMaterial(input: ProcessInput(inputValues: [CodeSigner.configuration: [
            "config": .value(try "codesignAllocatePath=\(other.path)".intern())]])))

        XCTAssertTrue(first.hasPrefix("allocate="), first)
        XCTAssertNotEqual(first, second)
    }
}
