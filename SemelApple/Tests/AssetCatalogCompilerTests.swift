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

    private func configuration(appIcon: String? = nil, symbols: AssetSymbolSettings? = nil) throws -> NodeValue {
        var text = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            platform=iphonesimulator
            minimumDeploymentTarget=18.0
            targetDevices=iphone,ipad
            assetutilPath=\(AppleToolDiscovery.locate("assetutil") ?? "/usr/bin/assetutil")
            """
        if let appIcon { text += "\nappIcon=\(appIcon)" }
        for (key, value) in (symbols?.literals ?? [:]).sorted(by: { $0.key < $1.key }) {
            text += "\n\(key)=\(value)"
        }
        return .value(try text.intern())
    }

    private var catalogListing: NodeValue {
        get throws { try manifestValue(catalog, files: ["Contents.json"], folders: ["AccentColor.colorset"]) }
    }

    /// With `treeArrived`, the catalog's tree is in (B-135): the catalog's own listing and
    /// the color set's below it.
    private func process(appIcon: String? = nil,
                         symbols: AssetSymbolSettings? = nil,
                         treeArrived: Bool = false,
                         files: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try AssetCatalogCompiler(thisNode: NodeRecord(id: 1, kind: AssetCatalogCompiler.kind))
        let listings = [catalog: try catalogListing,
                        "\(catalog)/AccentColor.colorset": try manifestValue("\(catalog)/AccentColor.colorset", files: ["Contents.json"])]
        return try node.process(input: ProcessInput(inputValues: [
            AssetCatalogCompiler.configuration: ["configuration": try configuration(appIcon: appIcon, symbols: symbols)],
            AssetCatalogCompiler.catalogs:      [catalog: try catalogListing],
            AssetCatalogCompiler.catalogTrees:  treeArrived ? try treeValues(from: listings).filter { $0.key == catalog } : [:],
            AssetCatalogCompiler.catalogFiles:  files,
        ]))
    }

    /// The whole catalog, as it stands once its tree and its files have arrived.
    private func processWholeCatalog(appIcon: String? = nil, symbols: AssetSymbolSettings? = nil) throws -> ProcessOutput {
        try process(appIcon: appIcon,
                    symbols: symbols,
                    treeArrived: true,
                    files: ["\(catalog)/Contents.json": .value(try "{}".intern()),
                            "\(catalog)/AccentColor.colorset/Contents.json": .value(try "{\"colors\":[]}".intern())])
    }

    // MARK: - Reading the catalog

    /// First pass: the catalog's tree is demanded with the file its own listing names,
    /// and nothing runs — actool over a catalog missing files would compile a wrong
    /// Assets.car without complaint.
    func test_demandsTheCatalogsTreeAndItsFilesBeforeRunning() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[AssetCatalogCompiler.catalogTrees]?.rendered,
                       [catalog: "Folder(path: '\(catalog)').subtreeManifest"])
        XCTAssertEqual(output.inputWireSpecs[AssetCatalogCompiler.catalogFiles]?.rendered,
                       ["\(catalog)/Contents.json": "StaticFile(path: '\(catalog)/Contents.json').output"])
        XCTAssertTrue(executor.invocations.isEmpty, "actool must not run on a partial catalog")
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[AssetCatalogCompiler.output]) else {
            return XCTFail("the tree is pending until the catalog is in")
        }
    }

    /// Once the tree has arrived every file below the catalog is demanded at once, however
    /// deep, and nothing runs until they are all in.
    func test_demandsEveryFileOfTheTreeOnceItHasArrived() throws {
        let output = try process(treeArrived: true, files: ["\(catalog)/Contents.json": .value(try "{}".intern())])

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

    // MARK: - Asset symbols (B-77 item 10)

    /// Asked for, a second run over the same catalogs writes their Swift symbols — the
    /// compile's arguments less its icon and plist, and the symbols' — published as actool
    /// wrote them on a port of their own; not asked for, there is one run and the port is
    /// empty.
    func test_aSecondRunWritesTheSymbolsWhenAsked() throws {
        let symbols = AssetSymbolSettings(bundleIdentifier: "app.codeedit.CodeEdit", generatesExtensions: true,
                                          frameworks: "SwiftUI UIKit AppKit")
        executor.producedTrees["out"] = ["Assets.car": try AssetCatalogCanonicaliserTests.widgetsCatalog(1)]
        executor.producedFiles["partial.plist"] = Array("<plist/>".utf8)
        executor.producedFiles["GeneratedAssetSymbols.swift"] = Array("extension ColorResource {}\n".utf8)

        let output = try processWholeCatalog(appIcon: "AppIcon", symbols: symbols)

        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertEqual(executor.invocations.first?.arguments.contains("--bundle-identifier"), false, "the compile is as it was")
        XCTAssertEqual(executor.lastArguments, [
            "Assets.xcassets",
            "--compile", "out",
            "--platform", "iphonesimulator",
            "--minimum-deployment-target", "18.0",
            "--target-device", "iphone",
            "--target-device", "ipad",
            "--bundle-identifier", "app.codeedit.CodeEdit",
            "--generate-swift-asset-symbol-extensions", "YES",
            "--generate-asset-symbol-framework-support", "SwiftUI UIKit AppKit",
            "--generate-swift-asset-symbols", "GeneratedAssetSymbols.swift",
            "--output-format", "human-readable-text",
        ])
        XCTAssertEqual(executor.lastInputFileNames, executor.invocations.first?.inputFileNames, "the same catalogs")
        XCTAssertEqual(executor.invocations.last?.expectedOutputFileNames, ["GeneratedAssetSymbols.swift"])
        XCTAssertEqual(executor.invocations.last?.expectedOutputFolders, [])
        XCTAssertEqual(try output.outputValues[AssetCatalogCompiler.swiftAssetSymbols]?.expectValue().resolveAsString(),
                       "extension ColorResource {}\n")
        XCTAssertEqual(try treeManifest(from: output.outputValues[AssetCatalogCompiler.output]).entries.map(\.path), ["Assets.car"])

        _ = try processWholeCatalog()
        XCTAssertEqual(executor.invocations.count, 3, "no symbols asked for, one run")
        XCTAssertFalse(executor.lastArguments.contains { $0.contains("symbol") }, "\(executor.lastArguments)")
    }

    /// The symbols are published with the catalog they describe, or not at all: an
    /// `Assets.car` that cannot be made canonical, or a failed run, is an error on the port.
    func test_theSymbolsAreNotPublishedWithoutTheCatalog() throws {
        let symbols = AssetSymbolSettings(bundleIdentifier: "com.example.App", generatesExtensions: false, frameworks: "SwiftUI")
        executor.producedTrees["out"] = ["Assets.car": Array("car".utf8)]
        executor.producedFiles["partial.plist"] = Array("<plist/>".utf8)
        executor.producedFiles["GeneratedAssetSymbols.swift"] = Array("extension ColorResource {}\n".utf8)

        let notCanonical = try XCTUnwrap(try processWholeCatalog(symbols: symbols)
            .outputValues[AssetCatalogCompiler.swiftAssetSymbols]?.errorDocument,
                                         "a catalog that is not published publishes no symbols")
        guard case .engine(.assetCatalogNotCanonical) = notCanonical.diagnostic else {
            return XCTFail("expected the catalog that is not canonical, got \(notCanonical)")
        }

        executor.exitCode = 1
        executor.errorOutput = "error: The operation could not be completed."
        let failed = try XCTUnwrap(try processWholeCatalog(symbols: symbols)
            .outputValues[AssetCatalogCompiler.swiftAssetSymbols]?.errorDocument, "a failed run publishes no symbols")
        XCTAssertEqual(failed.diagnostic, .tool(text: "error: The operation could not be completed.", tool: "actool"))
    }

    /// The real actool, over a catalog of colors made in two orders, writes the same symbols
    /// twice — in order of the name, no path in them — which is why they cross the port as
    /// actool writes them (B-89's invariant).
    func test_actoolWritesTheSameSymbolsForTheSameCatalog() throws {
        let actool = try XCTUnwrap(AppleToolDiscovery.locate("actool"), "no actool on this machine")
        var written: [String] = []
        for order in [["Zeta", "amber", "folderBlue"], ["folderBlue", "amber", "Zeta"]] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-symbols-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let catalog = folder.appendingPathComponent("Assets.xcassets")
            try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
            try #"{"info":{"author":"xcode","version":1}}"#.write(to: catalog.appendingPathComponent("Contents.json"),
                                                                atomically: true, encoding: .utf8)
            for name in order {
                let colorSet = catalog.appendingPathComponent("\(name).colorset")
                try FileManager.default.createDirectory(at: colorSet, withIntermediateDirectories: true)
                try #"{"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0.1","green":"0.6","red":"0.9"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
                    .write(to: colorSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
            }
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("out"), withIntermediateDirectories: true)
            let symbols = AssetSymbolSettings(bundleIdentifier: "com.example.App", generatesExtensions: true,
                                              frameworks: "SwiftUI UIKit AppKit")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: actool)
            // As the node's second run asks, with a partial plist asked for as well: told the
            // bundle identifier, actool writes the Swift and compiles nothing, which is why
            // the symbols are a run of their own.
            process.arguments = ["Assets.xcassets", "--compile", "out", "--platform", "macosx", "--minimum-deployment-target", "14.0",
                                 "--target-device", "mac", "--output-partial-info-plist", "partial.plist"]
                              + symbols.arguments(writingTo: "GeneratedAssetSymbols.swift")
                              + ["--output-format", "human-readable-text"]
            process.currentDirectoryURL = folder
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            written.append(try String(contentsOf: folder.appendingPathComponent("GeneratedAssetSymbols.swift"), encoding: .utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("out/Assets.car").path),
                           "a run writing symbols compiles nothing")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("partial.plist").path))
        }

        XCTAssertEqual(written[0], written[1])
        XCTAssertTrue(written[0].contains("static let amber = "), written[0])
        XCTAssertTrue(written[0].contains("extension SwiftUI.Color"), written[0])
        XCTAssertFalse(written[0].contains("semel-symbols-"), "no path is in the text")
    }

    func test_withoutAnAppIconNoneIsAskedFor() throws {
        _ = try processWholeCatalog()

        XCTAssertFalse(executor.lastArguments.contains("--app-icon"))
    }

    /// What actool wrote is the tree: every icon PNG it decided to make, and the car in
    /// canonical form (B-89) — two compiles that actool wrote differently publish one file.
    /// The partial plist is a value of its own.
    func test_whatActoolWroteIsTheTreeWithTheCarInCanonicalForm() throws {
        var published: [DataObjectHash] = []
        for compile in [1, 2] {
            executor.producedTrees["out"] = ["Assets.car":          try AssetCatalogCanonicaliserTests.widgetsCatalog(compile),
                                             "AppIcon60x60@2x.png": Array("png".utf8)]
            executor.producedFiles["partial.plist"] = Array("<plist/>".utf8)

            let output = try processWholeCatalog(appIcon: "AppIcon")

            let tree = try treeManifest(from: output.outputValues[AssetCatalogCompiler.output])
            XCTAssertEqual(tree.entries.map(\.path), ["AppIcon60x60@2x.png", "Assets.car"])
            XCTAssertEqual(tree.entries.first?.hash, try Array("png".utf8).intern(), "a PNG is published as actool wrote it")
            published.append(try XCTUnwrap(tree.entries.last?.hash))
            XCTAssertEqual(try output.outputValues[AssetCatalogCompiler.partialInfoPlist]?.expectValue().resolveAsString(),
                           "<plist/>")
        }

        XCTAssertEqual(published[0], published[1])
        XCTAssertEqual(published[0], try AssetCatalogCanonicaliser.canonicalise(try AssetCatalogCanonicaliserTests.widgetsCatalog(1)).bytes.intern())
    }

    /// An Assets.car the canonicaliser cannot read is published nowhere: the tree and the
    /// plist naming its icon both carry why.
    func test_aCarThatCannotBeMadeCanonicalIsNotPublished() throws {
        executor.producedTrees["out"] = ["Assets.car": Array("car".utf8)]
        executor.producedFiles["partial.plist"] = Array("<plist/>".utf8)

        let output = try processWholeCatalog(appIcon: "AppIcon")

        for port in [AssetCatalogCompiler.output, AssetCatalogCompiler.partialInfoPlist] {
            let document = try XCTUnwrap(output.outputValues[port]?.errorDocument, "\(port) must carry the error")
            XCTAssertEqual(document.diagnostic, .engine(.assetCatalogNotCanonical(problem: .notABOMStore(problem: .notABOMStore))))
            XCTAssertEqual(document.subject, .resource(path: "input:/app/Assets.xcassets"))
        }
    }

    func test_aFailedRunPutsActoolsErrorsOnEveryOutput() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: None of the input catalogs contained a matching app icon set named \"AppIcon\""

        let output = try processWholeCatalog(appIcon: "AppIcon")

        for port in [AssetCatalogCompiler.output, AssetCatalogCompiler.partialInfoPlist] {
            let document = try XCTUnwrap(output.outputValues[port]?.errorDocument, "\(port) must carry the error")
            XCTAssertEqual(document.diagnostic,
                           .tool(text: "error: None of the input catalogs contained a matching app icon set named \"AppIcon\"",
                                 tool: "actool"))
        }
    }

    /// actool puts its diagnostics on stdout under `--output-format human-readable-text`, so
    /// a run that fails with nothing on stderr must still carry what it said.
    func test_aFailedRunNamesTheStatusAndWhatActoolPrintedOnEitherStream() throws {
        executor.exitCode = 1
        executor.errorOutput = ""
        executor.infoOutput = "/* com.apple.actool.errors */\nAssets.xcassets: error: The operation could not be completed."

        let output = try processWholeCatalog(appIcon: "AppIcon")

        let document = try XCTUnwrap(output.outputValues[AssetCatalogCompiler.partialInfoPlist]?.errorDocument,
                                     "the partial plist must carry the error")
        XCTAssertEqual(document.diagnostic,
                       .tool(text: "/* com.apple.actool.errors */\nAssets.xcassets: error: The operation could not be completed.",
                             tool: "actool"))
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
            guard case .settingsMissing(let project, let machine, _)? = error as? ErrorCondition else {
                return XCTFail("expected the missing settings, got \(error)")
            }
            XCTAssertTrue(project.contains("apple.assetCatalogCompiler.platform"), "\(project)")
            XCTAssertTrue(project.contains("apple.assetCatalogCompiler.targetDevices"), "\(project)")
            // The assetutil that guards the canonical car is the machine's, written by prepare.
            XCTAssertTrue(machine.contains("apple.assetCatalogCompiler.assetutilPath"), "\(machine)")
        }
    }
}
