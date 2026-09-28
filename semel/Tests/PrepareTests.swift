//
//  PrepareTests.swift
//  SemelCLITests
//

import Foundation
import SemelApple
import SemelClang
import SemelMachineFile
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
        try SemelApple.register()
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
    private let actool = ToolDescriptor(name: "actool", version: "Apple actool version 26.6 (24765)", platform: "macOS",
                                        architecture: "arm64", recursiveHash: nil)
    private let xcstringstool = ToolDescriptor(name: "xcstringstool", version: "Xcode 26.6 (17F113)", platform: "macOS",
                                               architecture: "arm64", recursiveHash: nil)

    /// A machine with one SDK of each kind and every tool installed. The namespaces are
    /// the registry's, their machine settings answered from this machine rather than by
    /// xcrun: each key a plugin declares, from the SDK the fake has.
    private func facts(descriptors: [ToolDescriptor]? = nil, sdkIdentity: ((String) -> String?)? = nil) -> ToolchainFacts {
        let identity: (String) -> String? = sdkIdentity ?? { $0 == "iphonesimulator" ? "26.5 (23F81a)" : "26.5 (25F70)" }
        let namespaces = ToolNamespaceRegistry.all.map { entry in
            ToolNamespace(namespace: entry.namespace, toolName: entry.toolName, machineSettingKeys: entry.machineSettingKeys,
                          machineSettings: { platform in
                              var settings: [String: String] = [:]
                              for key in entry.machineSettingKeys.sorted() {
                                  switch key {
                                  case "sdk":        settings[key] = platform.sdkName
                                  case "sdkVersion": settings[key] = identity(platform.sdkName)
                                  case "sdkPath":    settings[key] = "/SDKs/\(platform.sdkName).sdk"
                                  default:           settings[key] = "unanswered"
                                  }
                              }
                              return settings
                          })
        }
        return ToolchainFacts(descriptors: descriptors ?? [swiftc, clang, swift, actool, xcstringstool],
                              namespaces: namespaces, sdkIdentity: identity)
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

    /// B-110. The targets the converter compiles, where SwiftPM puts them or where the
    /// manifest says; a test target is not one.
    func test_theSummaryNamesTheCompilableTargetsFolders() throws {
        let json = """
        {"name": "CLib", "dependencies": [], "platforms": [], "products": [],
         "targets": [{"name": "CLib", "type": "regular"},
                     {"name": "Tool", "type": "executable", "path": "Tools/Tool"},
                     {"name": "CLibTests", "type": "test"}]}
        """
        let summary = try PackageScan.summary(fromDumpPackageJSON: Data(json.utf8), folder: folder("CLib"))

        XCTAssertEqual(summary.targetFolders, [folder("CLib/Sources/CLib"), folder("CLib/Tools/Tool")])
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

    private var everyNamespace: [String] { ToolNamespaceRegistry.all.map(\.namespace) }

    /// B-109. The machine file: every namespace's tool descriptor, and the machine settings
    /// the plugin declares for it — the compiler's SDK by name and identity, clang's by
    /// path where the preprocessor and linker read it — and nothing of the project's.
    func test_theMachineConfigStatesTheToolsAndTheSDKFactsEachToolDeclares() throws {
        let config = lines(GeneratedFiles.machineConfig(platform: .iosSimulator, facts: facts(), namespaces: everyNamespace))

        XCTAssertTrue(config[0].hasPrefix("// Written by semel-swift prepare for --platform ios-simulator"), "got:\n\(config)")
        for namespace in ["swift.compiler", "swift.linker"] {
            XCTAssertTrue(config.contains("\(namespace).toolDescriptor.name=swiftc"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdk=iphonesimulator"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdkVersion=26.5 (23F81a)"), "got:\n\(config)")
        }
        XCTAssertTrue(config.contains("swift.packageReader.toolDescriptor.name=swift"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("swift.packageReader.sdk") }, "the reader declares no SDK")
        for namespace in ["clang.linker", "clang.preprocessor"] {
            XCTAssertTrue(config.contains("\(namespace).toolDescriptor.name=clang"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).sdkPath=/SDKs/iphonesimulator.sdk"), "got:\n\(config)")
        }
        XCTAssertTrue(config.contains("clang.compiler.toolDescriptor.name=clang"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("clang.compiler.sdkPath") }, "the compiler reads no SDK")
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.toolDescriptor.name=actool"), "got:\n\(config)")
        XCTAssertTrue(config.contains("apple.stringCatalogCompiler.toolDescriptor.name=xcstringstool"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.contains(".target=") || $0.contains("Standard=") },
                       "the project's choices are not the machine's, got:\n\(config)")
    }

    /// B-109. The project file: the target per tool at the deployment version, actool's
    /// platform facts, and the C standards under a comment naming them the choice they
    /// are — and no tool descriptor, which is the machine's.
    func test_theProjectConfigStatesTheTargetAndTheChoicesEachToolNeeds() throws {
        let config = lines(GeneratedFiles.projectConfig(platform: .iosSimulator, deploymentVersion: "18.0",
                                                        facts: facts(), namespaces: everyNamespace))

        XCTAssertTrue(config[0].hasPrefix("// Written by semel-swift prepare for --platform ios-simulator"), "got:\n\(config)")
        for namespace in ["swift.compiler", "swift.linker", "clang.compiler", "clang.linker", "clang.preprocessor"] {
            XCTAssertTrue(config.contains("\(namespace).target=arm64-apple-ios18.0-simulator"), "got:\n\(config)")
        }
        for namespace in ["clang.compiler", "clang.linker", "clang.preprocessor"] {
            let standard = try XCTUnwrap(config.firstIndex(of: "\(namespace).cStandard=gnu11"), "got:\n\(config)")
            XCTAssertTrue(config[standard - 1].hasPrefix("// prepare's starting point, not clang's default"), "got:\n\(config)")
            XCTAssertTrue(config.contains("\(namespace).cxxStandard=c++17"), "got:\n\(config)")
        }
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.platform=iphonesimulator"), "got:\n\(config)")
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.minimumDeploymentTarget=18.0"), "got:\n\(config)")
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.targetDevices=iphone,ipad"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("apple.stringCatalogCompiler") || $0.hasPrefix("swift.packageReader") },
                       "a tool with nothing of the project's to say has no block, got:\n\(config)")
        XCTAssertFalse(config.contains { $0.contains("toolDescriptor") || $0.contains("sdk") },
                       "the machine's facts are not the project's, got:\n\(config)")
    }

    /// B-68. A block nothing reads is reported as unused keys on every build, so the
    /// config carries the namespaces the formula's converters select from and no other:
    /// a tree of packages never links through clang and compiles no catalogs; a project
    /// compiles catalogs and still never links through clang.
    func test_theConfigCarriesOnlyTheNamespacesTheFormulaReads() throws {
        try write("Packages/Timeline/Package.swift")
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)

        try Preparation.run(folder: folder("Packages"), platform: .iosSimulator, steps: steps())
        try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        let packages = try String(contentsOf: folder("Packages").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        for namespace in ["swift.packageReader", "swift.compiler", "swift.linker"] {
            XCTAssertTrue(packages.contains("\(namespace).toolDescriptor.name="), "got:\n\(packages)")
        }
        XCTAssertFalse(packages.contains("clang."), "a tree with no C target reads no clang settings (B-110), got:\n\(packages)")
        XCTAssertFalse(packages.contains("apple."), "got:\n\(packages)")

        let project = try String(contentsOf: folder("App").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        for namespace in ["swift.packageReader", "swift.compiler", "swift.linker", "clang.preprocessor", "clang.compiler",
                          "apple.assetCatalogCompiler", "apple.stringCatalogCompiler"] {
            XCTAssertTrue(project.contains("\(namespace).toolDescriptor.name="), "got:\n\(project)")
        }
        XCTAssertFalse(project.contains("clang.linker"), "got:\n\(project)")
    }

    /// B-110. A target folder holding C sources and no Swift is compiled through clang, so
    /// that tree's config carries the clang blocks; the converter's own rule decides.
    func test_theConfigCarriesTheClangNamespacesWhenATargetIsCFamily() throws {
        try write("Packages/CLib/Package.swift")
        try write("Packages/CLib/Sources/CLib/lib.c", "int lib(void) { return 1; }\n")
        try write("Packages/CLib/Sources/CLib/include/lib.h", "int lib(void);\n")

        try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        let config = try String(contentsOf: folder("Packages").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        for namespace in ["swift.compiler", "clang.preprocessor", "clang.compiler"] {
            XCTAssertTrue(config.contains("\(namespace).toolDescriptor.name="), "got:\n\(config)")
        }
        XCTAssertFalse(config.contains("clang.linker"), "got:\n\(config)")
    }

    /// B-109. A machine file `semel-clang` wrote there — for a formula that includes both
    /// preludes — keeps its part: prepare rewrites its own, takes out of the other part the
    /// namespaces it writes itself (the clang compiler and preprocessor, for a C target),
    /// and leaves the rest. A second run finds the file as the first left it.
    func test_theMachineFileKeepsWhatSemelClangWroteThere() throws {
        try write("Packages/CLib/Package.swift")
        try write("Packages/CLib/Sources/CLib/lib.c", "int lib(void) { return 1; }\n")
        let machineFile = folder("Packages").appendingPathComponent("semel.machine.config")
        let clangPart = ToolNamespaceRegistry.all.filter { ["clang.compiler", "clang.linker"].contains($0.namespace) }
        try MachineFile.text(writtenBy: "semel-clang", platform: .macos, descriptors: [clang], namespaces: clangPart)
            .write(to: machineFile, atomically: true, encoding: .utf8)

        let report = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        XCTAssertEqual(report.machineFileKept, [MachineFile.Kept(writer: "semel-clang", namespaces: ["clang.linker"])])
        let text = try String(contentsOf: machineFile, encoding: .utf8)
        let sections = MachineFile.sections(in: text)
        XCTAssertEqual(sections.map(\.writer), ["semel-clang", "semel-swift prepare"], text)
        XCTAssertEqual(sections.map(\.namespaces), [["clang.linker"],
                                                     ["clang.compiler", "clang.preprocessor", "swift.compiler",
                                                      "swift.linker", "swift.packageReader"]], text)

        try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())
        XCTAssertEqual(try String(contentsOf: machineFile, encoding: .utf8), text)
    }

    /// B-55. The whole tree decides, as it does for the converter: a C target whose
    /// sources all sit in subfolders is still one, and a `.swift` in a subfolder makes a
    /// Swift target of a folder with a C source at its top.
    func test_aTargetFoldersNestedFilesDecideItsLanguage() throws {
        try write("Packages/CLib/Package.swift")
        try write("Packages/CLib/Sources/CLib/core/lib.c", "int lib(void) { return 1; }\n")
        try write("Packages/CLib/Sources/CLib/include/lib.h", "int lib(void);\n")
        try write("Packages/Mixed/Package.swift")
        try write("Packages/Mixed/Sources/Mixed/shim.c", "int shim(void) { return 1; }\n")
        try write("Packages/Mixed/Sources/Mixed/Views/Main.swift", "import Foundation\n")

        let summaries = [
            PackageSummary(name: "CLib", folder: folder("Packages/CLib"), pathDependencies: [], platforms: [:],
                           targetFolders: [folder("Packages/CLib/Sources/CLib")]),
            PackageSummary(name: "Mixed", folder: folder("Packages/Mixed"), pathDependencies: [], platforms: [:],
                           targetFolders: [folder("Packages/Mixed/Sources/Mixed")]),
        ]
        XCTAssertTrue(GeneratedFiles.hasCFamilyTargets(in: [summaries[0]]))
        XCTAssertFalse(GeneratedFiles.hasCFamilyTargets(in: [summaries[1]]))
    }

    /// B-122. The tree's languages are decided after vendoring: a Swift root whose git
    /// dependency brings a C target — swift-cmark under IceCubes — reads the clang
    /// settings like a tree with a C target of its own, and a scan taken before the copy
    /// could not see it. The nightly's fresh clone failed on exactly this.
    func test_theConfigCarriesTheClangNamespacesWhenAVendoredDependencyIsCFamily() throws {
        try write("Packages/App/Package.swift")
        try write("Packages/App/Sources/App/App.swift", "import Foundation\n")
        let vendoring: ([URL], URL) throws -> [Vendoring.Copied] = { _, into in
            let cmark = into.appendingPathComponent("cmark", isDirectory: true)
            try self.write(Preparation.relativePath(of: cmark.appendingPathComponent("Package.swift"), under: self.root))
            try self.write(Preparation.relativePath(of: cmark.appendingPathComponent("Sources/cmark/cmark.c"), under: self.root),
                           "int cmark(void) { return 1; }\n")
            return []
        }

        try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps(vendored: vendoring))

        let machine = try String(contentsOf: folder("Packages").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        let project = try String(contentsOf: folder("Packages").appendingPathComponent("semel.config"), encoding: .utf8)
        for namespace in ["swift.compiler", "clang.preprocessor", "clang.compiler"] {
            XCTAssertTrue(machine.contains("\(namespace).toolDescriptor.name="), "got:\n\(machine)")
        }
        XCTAssertTrue(project.contains("clang.compiler.target="), "the project half carries clang's target too, got:\n\(project)")
    }

    /// A namespace a converter reads that no toolchain declares would be silently left
    /// out of the config, and the build would then fail naming the missing key.
    func test_everyNamespaceAConverterReadsIsDeclaredByAToolchain() {
        let declared = Set(everyNamespace)

        for namespace in GeneratedFiles.packageTreeNamespaces(forCFamilyTargets: true) + GeneratedFiles.projectNamespaces {
            XCTAssertTrue(declared.contains(namespace), "\(namespace) is read but not declared; declared: \(declared.sorted())")
        }
    }

    /// A formula already there is kept, and it may select namespaces the converter's
    /// formula would not — a hand-written app formula compiles catalogs. The config
    /// carries what the kept formula selects too, read from its `prefix: '…'` literals.
    func test_theConfigCarriesTheNamespacesAKeptFormulaSelects() throws {
        try write("App/HelloKit/Package.swift")
        try write("App/semel.fmla", """
            func settings(prefix) = ConfigFilter(prefix: prefix, input: ['config': StaticFile(path: <semel.config>).output]).output
            include SwiftFormulaConverter(path: <HelloKit>, root: <.>).formula
            func assets() = AssetCatalogCompiler(configuration: ['config': settings(prefix: 'apple.assetCatalogCompiler')])
            func strings() = StringCatalogCompiler(configuration: ['config': settings(prefix: 'apple.stringCatalogCompiler')])
            """)

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(report.kept.map(\.lastPathComponent), ["semel.fmla"])
        let config = try String(contentsOf: folder("App").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("apple.assetCatalogCompiler.toolDescriptor.name=actool"), "got:\n\(config)")
        XCTAssertTrue(config.contains("apple.stringCatalogCompiler.toolDescriptor.name=xcstringstool"), "got:\n\(config)")
        XCTAssertTrue(config.contains("swift.compiler.toolDescriptor.name=swiftc"), "the package set is still there, got:\n\(config)")
    }

    func test_namespacesSelectedInFormulaTextAreTheDistinctPrefixLiterals() {
        let formula = "a(prefix: 'swift.compiler') b(prefix: 'clang.linker') c(prefix: 'swift.compiler') ConfigFilter(prefix: prefix, x)"

        XCTAssertEqual(MachineFile.namespaces(selectedIn: formula), ["clang.linker", "swift.compiler"])
    }

    /// B-108. A formula that includes a prelude names no prefix itself; the prelude funcs
    /// it calls do, and the funcs those call. A prelude included and never called selects
    /// nothing.
    func test_aFormulaSelectsWhatThePreludeFuncsItCallsSelect() throws {
        try SemelSwift.register()
        try SemelApple.register()
        let formula = "include 'swift'\ninclude 'apple'\nproduct 'x' = swift.executable(sources: <S>, name: 'X', settings: <c>)"

        XCTAssertEqual(MachineFile.namespaces(selectedIn: formula), ["swift.compiler", "swift.linker"])
    }

    /// The HelloApp fixture's calls: `apple.infoPlist` reaches the asset catalog compiler
    /// through `assets`, and `apple.resources` the string catalog compiler as well.
    func test_aPreludeFuncReachesTheFuncsItCalls() throws {
        try SemelApple.register()
        let formula = "include 'apple'\nproduct 'x' = apple.infoPlist(base: <I>, catalog: <A>, appIcon: 'I', settings: <c>)"
        let both    = formula + "\nproduct 'y/' = apple.resources(catalog: <A>, appIcon: 'I', strings: <R>, settings: <c>)"

        XCTAssertEqual(MachineFile.namespaces(selectedIn: formula), ["apple.assetCatalogCompiler"])
        XCTAssertEqual(MachineFile.namespaces(selectedIn: both), ["apple.assetCatalogCompiler", "apple.stringCatalogCompiler"])
    }

    func test_theConfigForMacOSNamesTheMacOSSDK() throws {
        let machine = lines(GeneratedFiles.machineConfig(platform: .macos, facts: facts(), namespaces: everyNamespace))
        let project = lines(GeneratedFiles.projectConfig(platform: .macos, deploymentVersion: "14.0",
                                                         facts: facts(), namespaces: everyNamespace))

        XCTAssertTrue(machine.contains("swift.compiler.sdk=macosx"), "got:\n\(machine)")
        XCTAssertTrue(machine.contains("swift.compiler.sdkVersion=26.5 (25F70)"), "got:\n\(machine)")
        XCTAssertTrue(project.contains("swift.compiler.target=arm64-apple-macosx14.0"), "got:\n\(project)")
    }

    /// A config names one version; of several installed, the newest.
    func test_aToolInstalledTwiceIsPinnedToTheNewest() throws {
        let config = lines(GeneratedFiles.machineConfig(platform: .macos,
                                                        facts: facts(descriptors: [olderSwiftc, swiftc, clang, swift]),
                                                        namespaces: everyNamespace))

        XCTAssertTrue(config.contains("swift.compiler.toolDescriptor.version=Apple Swift version 6.3.3"), "got:\n\(config)")
        XCTAssertFalse(config.contains("swift.compiler.toolDescriptor.version=Apple Swift version 6.2.0"))
    }

    func test_aMissingToolLeavesACommentNotASetting() throws {
        let config = lines(GeneratedFiles.machineConfig(platform: .macos, facts: facts(descriptors: [swiftc, swift]),
                                                        namespaces: everyNamespace))

        XCTAssertTrue(config.contains("// clang.compiler: no clang is installed on this machine"), "got:\n\(config)")
        XCTAssertFalse(config.contains { $0.hasPrefix("clang.compiler.toolDescriptor") })
    }

    /// Whatever the manifests declare: a machine without the platform's SDK cannot build
    /// for it, and prepare says so once rather than leaving every tool to.
    func test_aMissingSDKIsAnError() throws {
        try write("Packages/Timeline/Package.swift")

        XCTAssertThrowsError(try Preparation.run(folder: folder("Packages"), platform: .iosSimulator,
                                                 steps: steps(facts: facts(sdkIdentity: { _ in nil })))) { error in
            XCTAssertTrue("\(error)".contains("no iphonesimulator SDK"), "\(error)")
        }
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

    private func steps(vendored: @escaping ([URL], URL) throws -> [Vendoring.Copied] = { _, _ in [] },
                       facts: ToolchainFacts? = nil) -> Preparation.Steps {
        Preparation.Steps(
            summarize: { folder in
                let name = folder.lastPathComponent
                let dependsOn = name == "Timeline" ? [self.folder("Packages/Models")] : []
                // One target per package, at SwiftPM's default place, as the live scan
                // would read it from the manifest.
                return PackageSummary(name: name, folder: folder, pathDependencies: dependsOn,
                                      platforms: name == "Timeline" ? ["ios": "18.0"] : [:],
                                      targetFolders: [folder.appendingPathComponent("Sources/\(name)", isDirectory: true)])
            },
            vendor: vendored,
            vendorProject: { project, into in
                self.vendoredProject = (project, into)
                return []
            },
            facts: { facts ?? self.facts() })
    }

    private var vendoredProject: (URL, URL)?

    /// A project file in the OpenStep form Xcode writes, cut to what `prepare` reads: one
    /// application with a deployment target, and a project-level xcconfig.
    private let projectFixture = """
        // !$*UTF8*$!
        {
            objects = {
                P1 = { isa = PBXProject; buildConfigurationList = CL1; mainGroup = G1; targets = ( T1 ); };
                CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1 ); };
                C1 = { isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = XC1; buildSettings = { }; };
                XC1 = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = App.xcconfig; sourceTree = "<group>"; };
                G1 = { isa = PBXGroup; children = ( ); sourceTree = "<group>"; };
                T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application";
                       buildConfigurationList = CL2; buildPhases = ( ); fileSystemSynchronizedGroups = ( ); packageProductDependencies = ( ); };
                CL2 = { isa = XCConfigurationList; buildConfigurations = ( C2 ); };
                C2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { IPHONEOS_DEPLOYMENT_TARGET = 18.5; PRODUCT_NAME = App;
                       PRODUCT_BUNDLE_IDENTIFIER = "$(BUNDLE_ID_PREFIX).App"; }; };
            };
            rootObject = P1;
        }
        """

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
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["semel.fmla", "semel.config", "semel.machine.config"])
        let formula = try String(contentsOf: folder("Packages").appendingPathComponent("semel.fmla"), encoding: .utf8)
        XCTAssertTrue(formula.contains("include package(p: <Timeline>)"), "got:\n\(formula)")
        let config = try String(contentsOf: folder("Packages").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-ios18.0-simulator"), "got:\n\(config)")
    }

    // MARK: - A folder holding a project

    /// An `.xcodeproj` makes the folder a project: it is the one root, its packages are
    /// resolved through Xcode, the formula names the converter, and the config's target
    /// carries the application's deployment target.
    func test_aProjectIsTheRootAndItsDeploymentTargetIsTheBuilds() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("App/Packages/Models/Package.swift")

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(report.project, "App.xcodeproj")
        XCTAssertEqual(report.roots, [], "the project is the root, not the packages under it")
        XCTAssertEqual(vendoredProject?.0, folder("App/App.xcodeproj"))
        XCTAssertEqual(vendoredProject?.1, folder("App/Dependencies"))
        let formula = try String(contentsOf: folder("App").appendingPathComponent("semel.fmla"), encoding: .utf8)
        XCTAssertTrue(formula.contains("include XcodeProjectConverter(path: <App.xcodeproj>, root: <.>, configuration: 'Debug', sdk: 'iphonesimulator').formula"), "got:\n\(formula)")
        let config = try String(contentsOf: folder("App").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-ios18.5-simulator"), "got:\n\(config)")
    }

    func test_twoProjectsInOneFolderIsAnError() throws {
        try write("App/One.xcodeproj/project.pbxproj", projectFixture)
        try write("App/Two.xcodeproj/project.pbxproj", projectFixture)

        XCTAssertThrowsError(try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())) { error in
            XCTAssertTrue("\(error)".contains("One.xcodeproj") && "\(error)".contains("Two.xcodeproj"), "\(error)")
        }
    }

    // MARK: - The xcconfig a project names but does not ship

    /// B-70. A project may name an xcconfig its repository ignores and ship a
    /// `<name>.template` instead; a fresh clone then has the template and not the file,
    /// and the converter reads the missing file as an empty layer. `prepare` puts the
    /// template's copy in place, which is what a first-time Xcode user does by hand.
    func test_aMissingXcconfigTheProjectNamesIsCopiedFromItsTemplate() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("App/App.xcconfig.template", "BUNDLE_ID_PREFIX = com.example\n")

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        let xcconfig = folder("App").appendingPathComponent("App.xcconfig")
        XCTAssertEqual(try String(contentsOf: xcconfig, encoding: .utf8), "BUNDLE_ID_PREFIX = com.example\n")
        XCTAssertEqual(report.copiedFromTemplate,
                       [.init(file: xcconfig, source: folder("App").appendingPathComponent("App.xcconfig.template"))])
        XCTAssertEqual(report.missingXcconfigs, [])
        XCTAssertEqual(report.undefinedReferences, [], "nothing is missing, so nothing is reported undefined")
    }

    /// Xcode knows no template; the spelling is each repository's. The stem has to match
    /// the file the project names, and the marker is one of a short family, as a trailing
    /// extension or before `.xcconfig` with a dot or a dash.
    func test_aTemplateIsFoundUnderTheCommonSpellings() throws {
        let spellings = ["App.xcconfig.template", "App.xcconfig.example", "App.xcconfig.sample", "App.xcconfig.dist",
                         "App.example.xcconfig", "App-example.xcconfig", "App.template.xcconfig", "App-sample.xcconfig"]

        for (index, spelling) in spellings.enumerated() {
            let app = "App\(index)"
            try write("\(app)/App.xcodeproj/project.pbxproj", projectFixture)
            try write("\(app)/\(spelling)", "BUNDLE_ID_PREFIX = com.example\n")

            let report = try Preparation.run(folder: folder(app), platform: .iosSimulator, steps: steps())

            XCTAssertEqual(report.copiedFromTemplate.map(\.source.lastPathComponent), [spelling])
            XCTAssertEqual(try String(contentsOf: folder(app).appendingPathComponent("App.xcconfig"), encoding: .utf8),
                           "BUNDLE_ID_PREFIX = com.example\n", spelling)
        }
    }

    /// A sibling that only shares the stem is not a template: `App.xcconfig.bak` is
    /// someone's backup, and `AppSecrets.xcconfig` is another file.
    func test_aSiblingOutsideTheFamilyIsNotATemplate() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("App/App.xcconfig.bak", "BUNDLE_ID_PREFIX = com.old\n")
        try write("App/AppSecrets.xcconfig", "API_KEY = x\n")

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(report.copiedFromTemplate, [])
        XCTAssertEqual(report.missingXcconfigs, [folder("App").appendingPathComponent("App.xcconfig")])
    }

    /// The escape hatch: `--xcconfig App.xcconfig=<file>` names the starting point for a
    /// repository whose spelling the family does not cover. Named, it wins over a template.
    func test_aSourceNamedOnTheCommandLineIsCopiedAndWinsOverATemplate() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("App/App.xcconfig.template", "BUNDLE_ID_PREFIX = com.example\n")
        try write("Elsewhere/starting-point.xcconfig", "BUNDLE_ID_PREFIX = com.mine\n")

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator,
                                         xcconfigSources: ["App.xcconfig": folder("Elsewhere").appendingPathComponent("starting-point.xcconfig")],
                                         steps: steps())

        XCTAssertEqual(try String(contentsOf: folder("App").appendingPathComponent("App.xcconfig"), encoding: .utf8),
                       "BUNDLE_ID_PREFIX = com.mine\n")
        XCTAssertEqual(report.copiedFromTemplate.map(\.source.lastPathComponent), ["starting-point.xcconfig"])
    }

    func test_aSourceNamedForAFileTheProjectDoesNotNameIsAnError() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("Elsewhere/starting-point.xcconfig", "")

        XCTAssertThrowsError(try Preparation.run(folder: folder("App"), platform: .iosSimulator,
                                                 xcconfigSources: ["Other.xcconfig": folder("Elsewhere").appendingPathComponent("starting-point.xcconfig")],
                                                 steps: steps())) { error in
            XCTAssertTrue("\(error)".contains("Other.xcconfig") && "\(error)".contains("App.xcconfig"), "\(error)")
        }
    }

    func test_aSourceThatIsNotThereIsAnError() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)

        XCTAssertThrowsError(try Preparation.run(folder: folder("App"), platform: .iosSimulator,
                                                 xcconfigSources: ["App.xcconfig": folder("Elsewhere").appendingPathComponent("nope.xcconfig")],
                                                 steps: steps())) { error in
            XCTAssertTrue("\(error)".contains("nope.xcconfig"), "\(error)")
        }
    }

    /// When a named xcconfig is missing and nothing provides it, the report says which
    /// references the project's settings leave undefined — what a two-line file would
    /// have to define — rather than leaving the build to fail on each of them.
    func test_aMissingXcconfigReportsTheReferencesLeftUndefined() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(report.missingXcconfigs, [folder("App").appendingPathComponent("App.xcconfig")])
        XCTAssertEqual(report.undefinedReferences, ["BUNDLE_ID_PREFIX"])
    }

    /// The copy happens before the project is read for its deployment target, so a
    /// template that states one is honoured on the first run, not the second.
    func test_theTemplatesCopyIsReadForTheDeploymentTarget() throws {
        let fixture = projectFixture.replacingOccurrences(of: "IPHONEOS_DEPLOYMENT_TARGET = 18.5; ", with: "")
        try write("App/App.xcodeproj/project.pbxproj", fixture)
        try write("App/App.xcconfig.template", "IPHONEOS_DEPLOYMENT_TARGET = 17.2\n")

        try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        let config = try String(contentsOf: folder("App").appendingPathComponent("semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-ios17.2-simulator"), "got:\n\(config)")
    }

    func test_anXcconfigThatIsThereIsNeverReplaced() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)
        try write("App/App.xcconfig", "BUNDLE_ID_PREFIX = com.mine\n")
        try write("App/App.xcconfig.template", "BUNDLE_ID_PREFIX = com.example\n")

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        XCTAssertEqual(try String(contentsOf: folder("App").appendingPathComponent("App.xcconfig"), encoding: .utf8),
                       "BUNDLE_ID_PREFIX = com.mine\n")
        XCTAssertEqual(report.copiedFromTemplate, [])
        XCTAssertEqual(report.missingXcconfigs, [])
    }

    /// Without a template there is nothing to copy; the report says the file is missing
    /// rather than leaving the build to fail on every reference it would have defined.
    func test_aMissingXcconfigWithoutATemplateIsReportedNotWritten() throws {
        try write("App/App.xcodeproj/project.pbxproj", projectFixture)

        let report = try Preparation.run(folder: folder("App"), platform: .iosSimulator, steps: steps())

        let xcconfig = folder("App").appendingPathComponent("App.xcconfig")
        XCTAssertFalse(FileManager.default.fileExists(atPath: xcconfig.path))
        XCTAssertEqual(report.copiedFromTemplate, [])
        XCTAssertEqual(report.missingXcconfigs, [xcconfig])
    }

    /// A project that ships its own formula or config has already decided: neither is
    /// replaced, and the run says so instead. The machine file is nobody's decision, so
    /// it is written every time (B-109).
    func test_neverReplacesAFormulaOrConfigThatIsThereAndAlwaysRewritesTheMachineFile() throws {
        try write("Packages/Timeline/Package.swift")
        try write("Packages/semel.fmla", "// mine\n")
        try write("Packages/semel.machine.config", "// stale\n")

        let report = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        XCTAssertEqual(report.kept.map(\.lastPathComponent), ["semel.fmla"])
        XCTAssertEqual(report.written.map(\.lastPathComponent), ["semel.config", "semel.machine.config"])
        XCTAssertEqual(try String(contentsOf: folder("Packages").appendingPathComponent("semel.fmla"), encoding: .utf8),
                       "// mine\n")
        let machine = try String(contentsOf: folder("Packages").appendingPathComponent("semel.machine.config"), encoding: .utf8)
        XCTAssertTrue(machine.contains("swift.compiler.toolDescriptor.name=swiftc"), "got:\n\(machine)")
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

    // MARK: - Locks (B-06)

    /// A vendoring step that copies one package, GRDB, the way the live one does, with the
    /// pin its resolved file gives.
    private func vendoringGRDB(files: [String: String]) -> ([URL], URL) throws -> [Vendoring.Copied] {
        { _, into in
            let destination = into.appendingPathComponent("GRDB.swift", isDirectory: true)
            for (path, content) in files {
                try self.write(Preparation.relativePath(of: destination.appendingPathComponent(path), under: self.root), content)
            }
            return [Vendoring.Copied(name: "GRDB.swift", source: destination, destination: destination,
                                     pin: .init(origin: "https://github.com/groue/GRDB.swift.git", version: "7.11.1",
                                                revision: "b83108d10f42680d78f23fe4d4d80fc88dab3212"))]
        }
    }

    func test_writesALockBesideEachVendoredCopy() throws {
        try write("Packages/App/Package.swift")
        let vendoring = vendoringGRDB(files: ["Package.swift": "// grdb\n", "GRDB/Database.swift": "class Database {}\n"])

        let report = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps(vendored: vendoring))

        let lockFile = folder("Packages/Dependencies").appendingPathComponent("GRDB.swift.semel-lock")
        XCTAssertEqual(report.locks, [lockFile])
        let lock = try DependencyLock.parse(try String(contentsOf: lockFile, encoding: .utf8))
        XCTAssertEqual(lock, DependencyLock(contentRoot: try FolderContentRoot.root(ofFolderAt: folder("Packages/Dependencies/GRDB.swift")),
                                            fold:        FolderContentRoot.formatTag,
                                            version:     "7.11.1",
                                            revision:    "b83108d10f42680d78f23fe4d4d80fc88dab3212",
                                            origin:      "https://github.com/groue/GRDB.swift.git"))
    }

    /// A rerun vendors again and locks what it copied, so a lock never describes the copy
    /// before this one.
    func test_aRerunRewritesTheLockForWhatItCopied() throws {
        try write("Packages/App/Package.swift")
        let lockFile = folder("Packages/Dependencies").appendingPathComponent("GRDB.swift.semel-lock")
        _ = try Preparation.run(folder: folder("Packages"), platform: .macos,
                                steps: steps(vendored: vendoringGRDB(files: ["Package.swift": "// 7.11.1\n"])))
        let first = try String(contentsOf: lockFile, encoding: .utf8)

        _ = try Preparation.run(folder: folder("Packages"), platform: .macos,
                                steps: steps(vendored: vendoringGRDB(files: ["Package.swift": "// 7.12.0\n"])))

        let second = try DependencyLock.parse(try String(contentsOf: lockFile, encoding: .utf8))
        XCTAssertNotEqual(try DependencyLock.parse(first).contentRoot, second.contentRoot)
        XCTAssertEqual(second.contentRoot, try FolderContentRoot.root(ofFolderAt: folder("Packages/Dependencies/GRDB.swift")))
    }

    /// Two roots can both resolve one name into the one folder; the later copy stays, and
    /// the one lock is taken over it with its pin.
    func test_aNameVendoredTwiceIsLockedOnceWithTheLaterPin() throws {
        let destination = folder("Packages/Dependencies/Nuke")
        try write("Packages/Dependencies/Nuke/Package.swift", "// nuke\n")
        let copies = [Vendoring.Copied(name: "Nuke", source: destination, destination: destination,
                                       pin: .init(origin: "https://github.com/kean/Nuke.git", version: "12.0.0", revision: "a")),
                      Vendoring.Copied(name: "Nuke", source: destination, destination: destination,
                                       pin: .init(origin: "https://github.com/kean/Nuke.git", version: "12.1.0", revision: "b"))]

        let locks = try Preparation.writeLocks(for: copies)

        XCTAssertEqual(locks.count, 1)
        XCTAssertEqual(try DependencyLock.parse(try String(contentsOf: try XCTUnwrap(locks.first), encoding: .utf8)).version,
                       "12.1.0")
    }

    func test_nothingVendoredWritesNoLock() throws {
        try write("Packages/App/Package.swift")

        let report = try Preparation.run(folder: folder("Packages"), platform: .macos, steps: steps())

        XCTAssertEqual(report.locks, [])
    }
}
