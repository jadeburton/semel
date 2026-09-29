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

    private func errorMessage(_ value: NodeValue?) throws -> String {
        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(value) else {
            XCTFail("expected an error, got \(String(describing: value))")
            return ""
        }
        return try messageHash.resolveAsString()
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
        XCTAssertEqual(try treeManifest(from: output.outputValues[IBToolCompiler.output]).entries.map(\.path), ["Base.lproj/MainMenu.nib"])
    }

    /// A storyboard compiles to a folder of nibs, all of which travel in the tree.
    func test_compilesAStoryboardToAStoryboardcFolder() throws {
        executor.producedTrees["out"] = ["Main.storyboardc/Info.plist": Array("plist".utf8),
                                         "Main.storyboardc/UIViewController-abc.nib": Array("nib".utf8)]

        let output = try process(document: "Main.storyboard")

        XCTAssertTrue(executor.lastArguments.suffix(3) == ["--compile", "out/Main.storyboardc", "Main.storyboard"], "\(executor.lastArguments)")
        XCTAssertEqual(try treeManifest(from: output.outputValues[IBToolCompiler.output]).entries.map(\.path),
                       ["Main.storyboardc/Info.plist", "Main.storyboardc/UIViewController-abc.nib"])
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

        let message = try errorMessage(output.outputValues[IBToolCompiler.output])
        XCTAssertTrue(message.hasPrefix("ibtool exited with status 1"), message)
        XCTAssertTrue(message.contains("could not open the document"), message)
    }

    /// A clean exit with nothing written would put nothing in the bundle, and the app
    /// would fail at launch, far from here.
    func test_aCleanExitThatWroteNothingIsAnError() throws {
        let output = try process()

        XCTAssertEqual(try errorMessage(output.outputValues[IBToolCompiler.output]),
                       "ibtool exited with status 0 and wrote nothing at Base.lproj/MainMenu.nib")
    }

    func test_aDocumentThatIsNotInterfaceBuildersIsRefused() {
        XCTAssertThrowsError(try process(document: "Base.lproj/MainMenu.strings")) { error in
            XCTAssertTrue("\(error)".contains("is not an Interface Builder document"), "\(error)")
        }
    }

    func test_eachDocumentCompilesBesideItselfUnderItsCompiledExtension() {
        XCTAssertEqual(IBToolCompiler.compiledPath(of: "Base.lproj/MainMenu.xib"), "Base.lproj/MainMenu.nib")
        XCTAssertEqual(IBToolCompiler.compiledPath(of: "Main.storyboard"), "Main.storyboardc")
        XCTAssertNil(IBToolCompiler.compiledPath(of: "MainMenu.xcstrings"))
    }

    // MARK: - This machine

    /// NetNewsWire's main window, compiled twice by the real ibtool, each run in a sandbox
    /// of its own: a nib at its place, and the same bytes both times. Unlike actool's
    /// `Assets.car` (B-89), ibtool's output depends on nothing but its inputs and flags —
    /// found for five of NetNewsWire's Mac xibs, three runs each, and two storyboards and a
    /// xib of its iOS app (Xcode 26.6).
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
