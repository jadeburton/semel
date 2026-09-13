//
//  PrepareTests.swift
//  SemelCLITests
//

import Foundation
import SemelClang
import SemelNodeKit
import SemelSwift
@testable import SemelSwiftTool
import XCTest

/// B-59. `semel-swift prepare` derives what a tree of Swift packages needs before Semel can
/// build it. The machine-touching steps — SwiftPM, the network, xcrun — are handed in, so
/// these pin the derivation: which packages are roots, what the files say, and that a
/// file already there is never replaced.
final class PrepareTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-prepare-tests/\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SemelSwift.register()
        try SemelClang.register()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, _ content: String = "// swift-tools-version: 5.9\n") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func folder(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
    }

    private func summary(_ name: String, dependsOn: [String] = [], platforms: [String: String] = [:]) -> PackageSummary {
        PackageSummary(name: name, folder: folder(name),
                       pathDependencies: dependsOn.map(folder), platforms: platforms)
    }

    private let swiftc = ToolDescriptor(name: "swiftc", version: "Apple Swift version 6.3.3", platform: "macOS",
                                        architecture: "arm64", recursiveHash: nil)
    private let olderSwiftc = ToolDescriptor(name: "swiftc", version: "Apple Swift version 6.2.0", platform: "macOS",
                                             architecture: "arm64", recursiveHash: nil)
    private let clang = ToolDescriptor(name: "clang", version: "Apple clang version 21.0.0", platform: "macOS",
                                       architecture: "arm64", recursiveHash: nil)
    private let swift = ToolDescriptor(name: "swift", version: "Apple Swift version 6.3.3", platform: "macOS",
                                       architecture: "arm64", recursiveHash: nil)

    /// A machine with one SDK of each kind and every tool installed.
    private func facts(descriptors: [ToolDescriptor]? = nil) -> ToolchainFacts {
        ToolchainFacts(descriptors: descriptors ?? [swiftc, clang, swift],
                       namespaces: ToolNamespaceRegistry.all,
                       sdkPath: { "/SDKs/\($0).sdk" },
                       sdkIdentity: { $0 == "iphonesimulator" ? "26.5 (23F81a)" : "26.5 (25F70)" })
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    // MARK: - Finding packages

    /// A vendored dependency has a manifest of its own, and so does a checkout under
    /// `.build`; neither is a package of the tree.
    func test_findsEveryManifestExceptUnderDependenciesAndHiddenFolders() throws {
        try write("Package.swift")
        try write("Packages/Timeline/Package.swift")
        try write("Packages/Models/Package.swift")
        try write("Packages/Dependencies/Nuke/Package.swift")
        try write("Packages/Timeline/.build/checkouts/Nuke/Package.swift")
        try write("Packages/Timeline/Sources/Timeline/Timeline.swift")

        let found = try PackageScan.manifestFolders(under: root)

        XCTAssertEqual(found.map { Preparation.relativePath(of: $0, under: root) },
                       [".", "Packages/Models", "Packages/Timeline"])
    }

    /// dump-package's shape: `dependencies` is a list of one-key objects, `platforms` a
    /// list of name/version pairs. Everything else in it is ignored.
    func test_readsPathDependenciesAndPlatformsFromDumpPackage() throws {
        let json = """
        {"name": "Timeline", "toolsVersion": {"_version": "6.2.0"},
         "dependencies": [
           {"fileSystem": [{"identity": "models", "path": "\(folder("Models").path)"}]},
           {"sourceControl": [{"identity": "nuke", "location": {"remote": [{"urlString": "https://github.com/kean/Nuke.git"}]}}]}
         ],
         "platforms": [{"options": [], "platformName": "ios", "version": "18.0"},
                       {"options": [], "platformName": "visionos", "version": "1.0"}],
         "targets": [], "products": []}
        """
        let summary = try PackageScan.summary(fromDumpPackageJSON: Data(json.utf8), folder: folder("Timeline"))

        XCTAssertEqual(summary.name, "Timeline")
        XCTAssertEqual(summary.pathDependencies, [folder("Models")])
        XCTAssertEqual(summary.platforms, ["ios": "18.0", "visionos": "1.0"])
    }

    // MARK: - Roots

    /// IceCubes' shape: five packages nothing depends on, reached through which the rest
    /// are built. A package another one names by path publishes nothing of its own, so
    /// the formula must not name it.
    func test_theRootsAreThePackagesNothingDependsOnByPath() {
        let summaries = [
            summary("Timeline", dependsOn: ["Models", "StatusKit"]),
            summary("Explore", dependsOn: ["Models"]),
            summary("StatusKit", dependsOn: ["Models"]),
            summary("Models"),
        ]

        let roots = PackageScan.roots(of: summaries)

        XCTAssertEqual(roots.map(\.name), ["Explore", "Timeline"])
    }

    // MARK: - The formula

    func test_theFormulaNamesEachRootThroughOneBuildRoot() {
        let formula = GeneratedFiles.formula(rootPaths: ["Explore", "Timeline"])

        XCTAssertEqual(lines(formula).filter { !$0.hasPrefix("//") }, [
            "func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula",
            "include package(p: <Explore>)",
            "include package(p: <Timeline>)",
            "",
        ])
    }

    // MARK: - The config

    func test_theConfigStatesEveryNamespaceWithThePlatformSettingsItsToolNeeds() throws {
        let config = lines(try GeneratedFiles.config(platform: .iosSimulator, deploymentVersion: "18.0", facts: facts()))

        for namespace in ["swift.compiler", "swift.linker"] {
            XCTAssertTrue(config.contains("\(namespace).toolDescriptor.name=swiftc"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdk=iphonesimulator"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdkVersion=26.5 (23F81a)"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).target=arm64-apple-ios18.0-simulator"), "got:\n\(config)")
        }
        XCTAssertTrue(config.contains("swift.packageReader.toolDescriptor.name=swift"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("swift.packageReader.sdk") }, "the reader declares no SDK")
        for namespace in ["clang.compiler", "clang.linker", "clang.preprocessor"] {
            XCTAssertTrue(config.contains("\(namespace).toolDescriptor.name=clang"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdkPath=/SDKs/iphonesimulator.sdk"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).target=arm64-apple-ios18.0-simulator"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).cStandard=gnu11"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).cxxStandard=c++17"), "got:\n\(config)")
        }
    }

    func test_theConfigForMacOSNamesTheMacOSSDK() throws {
        let config = lines(try GeneratedFiles.config(platform: .macos, deploymentVersion: "14.0", facts: facts()))

        XCTAssertTrue(config.contains("swift.compiler.sdk=macosx"), "got:\n\(config)")
        XCTAssertTrue(config.contains("swift.compiler.sdkVersion=26.5 (25F70)"), "got:\n\(config)")
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-macosx14.0"), "got:\n\(config)")
    }

    /// A config names one version; of several installed, the newest.
    func test_aToolInstalledTwiceIsPinnedToTheNewest() throws {
        let config = lines(try GeneratedFiles.config(platform: .macos, deploymentVersion: "14.0",
                                                facts: facts(descriptors: [olderSwiftc, swiftc, clang, swift])))

        XCTAssertTrue(config.contains("swift.compiler.toolDescriptor.version=Apple Swift version 6.3.3"), "got:\n\(config)")
        XCTAssertFalse(config.contains("swift.compiler.toolDescriptor.version=Apple Swift version 6.2.0"))
    }

    func test_aMissingToolLeavesACommentNotASetting() throws {
        let config = lines(try GeneratedFiles.config(platform: .macos, deploymentVersion: "14.0",
                                                facts: facts(descriptors: [swiftc, swift])))

        XCTAssertTrue(config.contains("// clang.compiler: no clang is installed on this machine"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("clang.compiler.toolDescriptor") })
    }

    func test_aMissingSDKIsAnError() {
        var machine = facts()
        machine.sdkIdentity = { _ in nil }

        XCTAssertThrowsError(try GeneratedFiles.config(platform: .iosSimulator, deploymentVersion: "18.0", facts: machine))
    }

    // MARK: - Deployment version

    /// A root declaring 18.0 cannot be built for 17.0 whatever its dependencies allow.
    func test_theDeploymentVersionIsTheHighestAnyPackageDeclares() {
        let summaries = [summary("A", platforms: ["ios": "17.0"]),
                         summary("B", platforms: ["ios": "18.0", "macos": "14.0"]),
                         summary("C")]

        XCTAssertEqual(GeneratedFiles.deploymentVersion(for: .iosSimulator, in: summaries), "18.0")
        XCTAssertEqual(GeneratedFiles.deploymentVersion(for: .macos, in: summaries), "14.0")
        XCTAssertNil(GeneratedFiles.deploymentVersion(for: .macos, in: [summary("C")]))
    }

    func test_theSDKVersionIsItsIdentityWithoutTheBuild() {
        XCTAssertEqual(GeneratedFiles.version(fromSDKIdentity: "26.5 (23F81a)"), "26.5")
    }

    // MARK: - Running it

    private func steps(vendored: @escaping ([URL], URL) throws -> [Vendoring.Copied] = { _, _ in [] }) -> Preparation.Steps {
        Preparation.Steps(
            summarize: { folder in
                let name = folder.lastPathComponent
                let dependsOn = name == "Timeline" ? [self.folder("Packages/Models")] : []
                return PackageSummary(name: name, folder: folder, pathDependencies: dependsOn,
                                      platforms: name == "Timeline" ? ["ios": "18.0"] : [:])
            },
            vendor: vendored,
            facts: { self.facts() })
    }

    func test_writesTheFormulaAndConfigBesideThePackagesAndVendorsTheRoots() throws {
        try write("Packages/Timeline/Package.swift")
        try write("Packages/Models/Package.swift")
        var vendoredRoots: [URL] = []
        var vendoredInto: URL?

        let report = try Preparation.run(folder: folder("Packages"), platform: .iosSimulator,
                                            steps: steps(vendored: { roots, into in
                                                vendoredRoots = roots
                                                vendoredInto = into
                                                return []
                                            }))

        XCTAssertEqual(report.roots.map(\.name), ["Timeline"])
        XCTAssertEqual(vendoredRoots, [folder("Packages/Timeline")])
        XCTAssertEqual(vendoredInto, folder("Packages/Dependencies"))
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["semel.fmla", "semel.config"])
        let formula = try String(contentsOf: folder("Packages").appendingPathComponent("semel.fmla"), encoding: .utf8)
        XCTAssertTrue(formula.contains("include package(p: <Timeline>)"), "got:\n\(formula)")
        let config = try String(contentsOf: folder("Packages").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-ios18.0-simulator"), "got:\n\(config)")
    }

    /// A project that ships its own formula or config has already decided: neither is
    /// replaced, and the run says so instead.
    func test_neverReplacesAFormulaOrConfigThatIsThere() throws {
        try write("Packages/Timeline/Package.swift")
        try write("Packages/semel.fmla", "// mine\n")

        let report = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        XCTAssertEqual(report.kept.map(\.lastPathComponent), ["semel.fmla"])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["semel.config"])
        XCTAssertEqual(try String(contentsOf: folder("Packages").appendingPathComponent("semel.fmla"), encoding: .utf8),
                       "// mine\n")
    }

    /// No manifest declares a macOS version, so the SDK's own version is the deployment
    /// version — everything the SDK has is allowed.
    func test_fallsBackToTheSDKVersionWhenNoPackageDeclaresOne() throws {
        try write("Packages/Models/Package.swift")

        _ = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        let config = try String(contentsOf: folder("Packages").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-macosx26.5"), "got:\n\(config)")
    }

    func test_aFolderWithNoPackageIsAnError() {
        XCTAssertThrowsError(try Preparation.run(folder: root, platform: .macos, steps: steps()))
    }

    /// The folder itself can be the package, as for a single-package repository.
    func test_theFolderItselfCanBeTheOnlyRoot() throws {
        try write("Package.swift")

        let report = try Preparation.run(folder: root, platform: .macos, steps: steps())

        XCTAssertEqual(report.roots.map(\.folder), [root])
        let formula = try String(contentsOf: root.appendingPathComponent("semel.fmla"), encoding: .utf8)
        XCTAssertTrue(formula.contains("include package(p: <.>)"), "got:\n\(formula)")
    }
}
