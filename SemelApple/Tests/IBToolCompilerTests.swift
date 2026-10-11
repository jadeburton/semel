//
//  IBToolCompilerTests.swift
//  SemelAppleTests
//
//  ibtool compiles one Interface Builder document to what an app loads, placed where the
//  document sits in the bundle (B-77).
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class IBToolCompilerTests: SemelAppleTestCase {

    private let descriptor = ToolDescriptor(name: "ibtool", version: "Apple ibtool version 26.6 (24765)", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func configuration(module: String? = "NetNewsWire", omitting omitted: String? = nil) -> String {
        var lines = [
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "sdkPath=/SDKs/MacOSX.sdk",
            "minimumDeploymentTarget=15.0",
            "targetDevices=mac",
        ]
        if let module {
            lines.append("module=\(module)")
        }
        return lines.filter { omitted == nil || !$0.hasPrefix("\(omitted ?? "")=") }.joined(separator: "\n")
    }

    private func process(document: String = "Base.lproj/MainMenu.xib", configuration: String? = nil) throws -> ProcessOutput {
        let node = try IBToolCompiler(thisNode: NodeRecord(id: 1, kind: IBToolCompiler.kind))
        return try node.process(input: ProcessInput(inputValues: [
            IBToolCompiler.configuration: ["configuration": .value(try (configuration ?? self.configuration()).intern())],
            IBToolCompiler.document: [document: .value(try "<document/>".intern())],
        ]))
    }

    private func errorDocument(_ value: NodeValue?) throws -> ErrorDocument {
        try XCTUnwrap(try XCTUnwrap(value).errorDocument, "expected an error, got \(String(describing: value))")
    }

    /// The document goes in at the path its wire names — its place in the bundle — and
    /// the compiled document comes out at the same place with its compiled extension, as
    /// Xcode passes the flags: the module a class is looked up in, the device, the
    /// deployment target and the SDK.
    func test_compilesAXibToANibAtItsPlaceInTheBundle() throws {
        executor.producedTrees["out"] = ["Base.lproj/MainMenu.nib": Array("nib".utf8)]

        let output = try process()

        XCTAssertEqual(executor.lastInputFileNames, ["Base.lproj/MainMenu.xib"])
        XCTAssertEqual(executor.lastArguments, ["--errors", "--warnings", "--notices",
                                                "--module", "NetNewsWire",
                                                "--target-device", "mac",
                                                "--minimum-deployment-target", "15.0",
                                                "--output-format", "human-readable-text",
                                                "--sdk", "/SDKs/MacOSX.sdk",
                                                "--compile", "out/Base.lproj/MainMenu.nib", "Base.lproj/MainMenu.xib"])
        XCTAssertEqual(executor.invocations.last?.expectedOutputFolders, ["out"])
        // A daemon of its own, never one of the pool another run left in its folder (B-152).
        XCTAssertEqual(executor.invocations.last?.environment, ["IBToolNeverDeque": "YES"])
        XCTAssertEqual(try treeManifest(from: output.outputValues[IBToolCompiler.output]).entries.map(\.path), ["Base.lproj/MainMenu.nib"])
    }

    /// A storyboard compiles to a folder of nibs, all of which travel in the tree.
    func test_compilesAStoryboardToAStoryboardcFolder() throws {
        let index = try PropertyListSerialization.data(fromPropertyList: ["UIStoryboardDesignatedEntryPointIdentifier": "abc"],
                                                       format: .binary, options: 0)
        executor.producedTrees["out"] = ["Main.storyboardc/Info.plist": [UInt8](index),
                                         "Main.storyboardc/UIViewController-abc.nib": Array("nib".utf8)]

        let output = try process(document: "Main.storyboard")

        XCTAssertTrue(executor.lastArguments.suffix(3) == ["--compile", "out/Main.storyboardc", "Main.storyboard"], "\(executor.lastArguments)")
        XCTAssertEqual(try treeManifest(from: output.outputValues[IBToolCompiler.output]).entries.map(\.path),
                       ["Main.storyboardc/Info.plist", "Main.storyboardc/UIViewController-abc.nib"])
    }

    /// A storyboard's index that is not a property list cannot have its UUIDs put in
    /// canonical form, and is refused rather than published as ibtool wrote it (B-154).
    func test_aStoryboardIndexThatDoesNotReadIsRefused() throws {
        executor.producedTrees["out"] = ["Main.storyboardc/Info.plist": Array("not a plist".utf8)]

        let output = try process(document: "Main.storyboard")

        XCTAssertEqual(try errorDocument(output.outputValues[IBToolCompiler.output]).diagnostic,
                       .engine(.nibNotCanonical(file: "Main.storyboardc/Info.plist", problem: .storyboardIndexUnreadable)))
    }

    /// No module is no `--module`: a document whose classes name their module needs none.
    func test_withoutAModuleNoneIsPassed() throws {
        executor.producedTrees["out"] = ["MainMenu.nib": Array("nib".utf8)]

        _ = try process(document: "MainMenu.xib", configuration: configuration(module: nil))

        XCTAssertFalse(executor.lastArguments.contains("--module"), "\(executor.lastArguments)")
    }

    /// The SDK is the machine's and the rest the project's; each is required, and missing
    /// is said by key rather than left to ibtool's defaults.
    func test_theSDKTheDeploymentTargetAndTheDevicesAreRequired() throws {
        for key in ["sdkPath", "minimumDeploymentTarget", "targetDevices"] {
            XCTAssertThrowsError(try process(configuration: configuration(omitting: key)), key) { error in
                XCTAssertTrue("\(error)".contains("apple.ibToolCompiler.\(key)"), "\(error)")
            }
        }
    }

    func test_aFailedRunIsTheToolsError() throws {
        executor.exitCode = 1
        executor.infoOutput = "/* com.apple.ibtool.errors */\nMainMenu.xib: error: Interface Builder could not open the document"

        let output = try process()

        XCTAssertEqual(try errorDocument(output.outputValues[IBToolCompiler.output]),
                       ErrorDocument(diagnostic: .tool(text: "/* com.apple.ibtool.errors */\nMainMenu.xib: error: Interface Builder "
                                                           + "could not open the document", tool: "ibtool"),
                                     subject: .resource(path: "Base.lproj/MainMenu.xib"), remedy: nil))
    }

    /// A clean exit with nothing written would put nothing in the bundle, and the app
    /// would fail at launch, far from here.
    func test_aCleanExitThatWroteNothingIsAnError() throws {
        let output = try process()

        XCTAssertEqual(try errorDocument(output.outputValues[IBToolCompiler.output]).diagnostic,
                       .engine(.toolWroteNothing(tool: "ibtool", status: 0, paths: ["Base.lproj/MainMenu.nib"])))
    }

    func test_aDocumentThatIsNotInterfaceBuildersIsRefused() {
        XCTAssertThrowsError(try process(document: "Base.lproj/MainMenu.strings")) { error in
            XCTAssertEqual(error as? ErrorCondition,
                           .notAnInterfaceBuilderDocument(path: "Base.lproj/MainMenu.strings", compiles: [".storyboard", ".xib"]))
        }
    }

    func test_eachDocumentCompilesBesideItselfUnderItsCompiledExtension() {
        XCTAssertEqual(IBToolCompiler.compiledPath(of: "Base.lproj/MainMenu.xib"), "Base.lproj/MainMenu.nib")
        XCTAssertEqual(IBToolCompiler.compiledPath(of: "Main.storyboard"), "Main.storyboardc")
        XCTAssertNil(IBToolCompiler.compiledPath(of: "MainMenu.xcstrings"))
    }

    /// Each document is compiled twice, and the same output both times is published.
    func test_eachDocumentIsCompiledTwice() throws {
        executor.producedTrees["out"] = ["Base.lproj/MainMenu.nib": Array("nib".utf8)]

        let output = try process()

        XCTAssertEqual(executor.invocations.count, 2)
        XCTAssertEqual(try treeManifest(from: output.outputValues[IBToolCompiler.output]).entries.map(\.path), ["Base.lproj/MainMenu.nib"])
    }

    /// A document ibtool compiles to two different outputs from one input — Sequel Ace's
    /// `ImportAccessory.xib`, whose misplaced frames it updates afresh each run — is
    /// refused, naming the file that differed, with the document to resolve (B-154).
    func test_aDocumentCompiledToTwoOutputsIsRefused() throws {
        executor.producedTreesByRun = [["out": ["Base.lproj/MainMenu.nib": Array("one layout".utf8)]],
                                       ["out": ["Base.lproj/MainMenu.nib": Array("another".utf8)]]]

        let output = try process()

        XCTAssertEqual(try errorDocument(output.outputValues[IBToolCompiler.output]),
                       ErrorDocument.engine(.toolOutputVaries(tool: "ibtool", path: "Base.lproj/MainMenu.nib"),
                                            subject: .resource(path: "Base.lproj/MainMenu.xib"),
                                            remedy: .resolveLayout(document: "Base.lproj/MainMenu.xib")))
    }

    // MARK: - This machine

    /// Sequel Ace's `ProgressWindowController.storyboard` compiled by the real ibtool three
    /// times: ibtool gives its view controllers fresh UUIDs and lists its connections in a
    /// new order every run, and the node publishes one tree all three times, the UUIDs the
    /// ones derived from the document (B-154).
    func test_theRealIBToolsStoryboardComesOutAsOneTree() throws {
        let ibtool = try XCTUnwrap(AppleToolDiscovery.locate("ibtool"), "ibtool must be discoverable via xcrun")
        let sdkPath = try XCTUnwrap(SemelApple.sdkPath(forPlatform: .macos))
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: ibtool))
        let storyboard = SequelAceFixtureTests.sequelAce.appendingPathComponent("Source/Controllers/Other/ProgressWindowController.storyboard")
        let configuration = self.configuration(module: "Sequel_Ace").replacingOccurrences(of: "/SDKs/MacOSX.sdk", with: sdkPath)

        var trees: [TreeManifest] = []
        for _ in 0..<3 {
            let node = try IBToolCompiler(thisNode: NodeRecord(id: 1, kind: IBToolCompiler.kind))
            let output = try node.process(input: ProcessInput(inputValues: [
                IBToolCompiler.configuration: ["configuration": .value(try configuration.intern())],
                IBToolCompiler.document: ["ProgressWindowController.storyboard": .value(try DataObjectStore.shared.store(fileAt: storyboard))],
            ]))
            trees.append(try treeManifest(from: output.outputValues[IBToolCompiler.output]))
        }

        XCTAssertEqual(trees[0], trees[1])
        XCTAssertEqual(trees[0], trees[2])
        let plist = try XCTUnwrap(trees[0].entries.first { $0.path == "ProgressWindowController.storyboardc/Info.plist" }?.hash)
        let index = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(try plist.resolve()), format: nil) as? [String: Any])
        XCTAssertEqual((index["NSViewControllerIdentifiersToUUIDs"] as? [String: String])?["ProgressViewController"],
                       NibCanonicaliser.derivedUUID(document: "ProgressWindowController.storyboard", identifier: "ProgressViewController"))
    }

    /// NetNewsWire's main window, compiled by the real ibtool: a nib at its place, the same
    /// tree twice. ibtool writes this xib the same way every run, and its canonical form is
    /// the same nib, its tables reordered.
    func test_theRealIBToolCompilesNetNewsWiresMainWindowToTheSameBytesTwice() throws {
        let ibtool = try XCTUnwrap(AppleToolDiscovery.locate("ibtool"), "ibtool must be discoverable via xcrun")
        let sdkPath = try XCTUnwrap(SemelApple.sdkPath(forPlatform: .macos))
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: ibtool))
        let xib = XcodeBuildSettingsTests.netNewsWire.appendingPathComponent("Mac/MainWindow/Base.lproj/MainWindow.xib")
        let configuration = self.configuration().replacingOccurrences(of: "/SDKs/MacOSX.sdk", with: sdkPath)

        var trees: [TreeManifest] = []
        for _ in 0..<2 {
            let node = try IBToolCompiler(thisNode: NodeRecord(id: 1, kind: IBToolCompiler.kind))
            let output = try node.process(input: ProcessInput(inputValues: [
                IBToolCompiler.configuration: ["configuration": .value(try configuration.intern())],
                IBToolCompiler.document: ["Base.lproj/MainWindow.xib": .value(try DataObjectStore.shared.store(fileAt: xib))],
            ]))
            trees.append(try treeManifest(from: output.outputValues[IBToolCompiler.output]))
        }

        XCTAssertEqual(trees[0].entries.map(\.path), ["Base.lproj/MainWindow.nib"])
        XCTAssertEqual(trees[0].entries.map(\.hash), trees[1].entries.map(\.hash))
    }
}
