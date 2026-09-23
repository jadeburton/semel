//
//  AssetCatalogCompilerTests.swift
//  SemelAppleTests
//
//  The node's work is walking the catalog to every file, laying it out in the sandbox
//  under its own name, assembling actool's command line, and turning what actool wrote
//  into a tree. A recording runner makes all four observable without running actool.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class AssetCatalogCompilerTests: SemelAppleTestCase {

    private let descriptor = ToolDescriptor(name: "actool", version: "test-actool", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    // MARK: - Helpers

    private let catalog = "input:/app/Assets.xcassets"

    private func configuration(appIcon: String? = nil) throws -> NodeValue {
        var text = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            platform=iphonesimulator
            minimumDeploymentTarget=18.0
            targetDevices=iphone,ipad
            """
        if let appIcon { text += "\nappIcon=\(appIcon)" }
        return .value(try text.intern())
    }

    private func process(appIcon: String? = nil,
                         subfolders: [String: NodeValue] = [:],
                         files: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind))
        return try node.process(input: ProcessInput(inputValues: [
            AssetCatalogCompiler.configuration:     ["configuration": try configuration(appIcon: appIcon)],
            AssetCatalogCompiler.catalogs:          [catalog: try manifestValue(catalog, files: ["Contents.json"],
                                                                                folders: ["AccentColor.colorset"])],
            AssetCatalogCompiler.catalogSubfolders: subfolders,
            AssetCatalogCompiler.catalogFiles:      files,
        ]))
    }

    /// The whole catalog, as it stands once the walk has finished.
    private func processWholeCatalog(appIcon: String? = nil) throws -> ProcessOutput {
        try process(appIcon: appIcon,
                    subfolders: ["\(catalog)/AccentColor.colorset":
                                     try manifestValue("\(catalog)/AccentColor.colorset", files: ["Contents.json"])],
                    files: ["\(catalog)/Contents.json": .value(try "{}".intern()),
                            "\(catalog)/AccentColor.colorset/Contents.json": .value(try "{\"colors\":[]}".intern())])
    }

    // MARK: - The walk

    /// First pass: the catalog's manifest names a file and a subfolder, so both are
    /// demanded, and nothing runs — actool over a catalog missing files would compile a
    /// wrong Assets.car without complaint.
    func test_demandsEverySubfolderAndFileBeforeRunning() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[AssetCatalogCompiler.catalogSubfolders],
                       ["\(catalog)/AccentColor.colorset": "Folder(path: '\(catalog)/AccentColor.colorset').manifest"])
        XCTAssertEqual(output.inputWireSpecs[AssetCatalogCompiler.catalogFiles],
                       ["\(catalog)/Contents.json": "StaticFile(path: '\(catalog)/Contents.json').output"])
        XCTAssertTrue(executor.invocations.isEmpty, "actool must not run on a partial catalog")
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[AssetCatalogCompiler.output]) else {
            return XCTFail("the tree is pending until the walk is done")
        }
    }

    /// A subfolder that has arrived is walked in turn, so the demand grows until the tree
    /// is exhausted.
    func test_walksASubfolderOnceItsManifestHasArrived() throws {
        let output = try process(subfolders: ["\(catalog)/AccentColor.colorset":
                                                  try manifestValue("\(catalog)/AccentColor.colorset", files: ["Contents.json"])],
                                 files: ["\(catalog)/Contents.json": .value(try "{}".intern())])

        XCTAssertEqual(output.inputWireSpecs[AssetCatalogCompiler.catalogFiles]?.keys.sorted(),
                       ["\(catalog)/AccentColor.colorset/Contents.json", "\(catalog)/Contents.json"])
        XCTAssertTrue(executor.invocations.isEmpty, "one file is still to come")
    }

    // MARK: - The run

    func test_laysTheCatalogOutUnderItsOwnNameAndCompilesItForThePlatform() throws {
        _ = try processWholeCatalog(appIcon: "AppIcon")

        XCTAssertEqual(executor.lastInputFileNames,
                       ["Assets.xcassets/AccentColor.colorset/Contents.json", "Assets.xcassets/Contents.json"])
        XCTAssertEqual(executor.lastArguments, [
            "Assets.xcassets",
            "--compile", "out",
            "--platform", "iphonesimulator",
            "--minimum-deployment-target", "18.0",
            "--target-device", "iphone",
            "--target-device", "ipad",
            "--app-icon", "AppIcon",
            "--output-partial-info-plist", "partial.plist",
            "--output-format", "human-readable-text",
        ])
        XCTAssertEqual(executor.invocations.last?.expectedOutputFolders, ["out"])
        XCTAssertEqual(executor.invocations.last?.expectedOutputFileNames, ["partial.plist"])
    }

    func test_withoutAnAppIconNoneIsAskedFor() throws {
        _ = try processWholeCatalog()

        XCTAssertFalse(executor.lastArguments.contains("--app-icon"))
    }

    /// What actool wrote is the tree: the car and every icon PNG it decided to make, and
    /// the partial plist is a value of its own.
    func test_whatActoolWroteIsTheTreeAndThePartialPlist() throws {
        executor.producedTrees["out"] = ["Assets.car": Array("car".utf8), "AppIcon60x60@2x.png": Array("png".utf8)]
        executor.producedFiles["partial.plist"] = Array("<plist/>".utf8)

        let output = try processWholeCatalog(appIcon: "AppIcon")

        let tree = try treeManifest(from: output.outputValues[AssetCatalogCompiler.output])
        XCTAssertEqual(tree.entries.map(\.path), ["AppIcon60x60@2x.png", "Assets.car"])
        XCTAssertEqual(try output.outputValues[AssetCatalogCompiler.partialInfoPlist]?.expectValue().resolveAsString(),
                       "<plist/>")
    }

    func test_aFailedRunPutsActoolsErrorsOnEveryOutput() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: None of the input catalogs contained a matching app icon set named \"AppIcon\""

        let output = try processWholeCatalog(appIcon: "AppIcon")

        for port in [AssetCatalogCompiler.output, AssetCatalogCompiler.partialInfoPlist] {
            guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[port]) else {
                return XCTFail("\(port) must carry the error")
            }
            XCTAssertTrue(try messageHash.resolveAsString().contains("AppIcon"))
        }
    }

    /// actool puts its diagnostics on stdout under `--output-format human-readable-text`, so
    /// a run that fails with nothing on stderr must still say what it said, and the exit
    /// status is there when it said nothing.
    func test_aFailedRunNamesTheStatusAndWhatActoolPrintedOnEitherStream() throws {
        executor.exitCode = 1
        executor.errorOutput = ""
        executor.infoOutput = "/* com.apple.actool.errors */\nAssets.xcassets: error: The operation could not be completed."

        let output = try processWholeCatalog(appIcon: "AppIcon")

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[AssetCatalogCompiler.partialInfoPlist]) else {
            return XCTFail("the partial plist must carry the error")
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.hasPrefix("actool exited with status 1"), message)
        XCTAssertTrue(message.contains("The operation could not be completed."), message)
    }

    /// The tree is what the platform settings produced, so they are required: a catalog
    /// compiled for no platform in particular is not a build.
    func test_thePlatformSettingsAreRequired() throws {
        let node = try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind))
        let bare = """
            toolDescriptor.name=actool
            toolDescriptor.version=test-actool
            toolDescriptor.platform=macOS
            toolDescriptor.architecture=arm64
            """

        XCTAssertThrowsError(try node.process(input: ProcessInput(inputValues: [
            AssetCatalogCompiler.configuration: ["configuration": .value(try bare.intern())],
        ]))) { error in
            XCTAssertTrue("\(error)".contains("apple.assetCatalogCompiler.platform"), "\(error)")
            XCTAssertTrue("\(error)".contains("apple.assetCatalogCompiler.targetDevices"), "\(error)")
        }
    }
}
