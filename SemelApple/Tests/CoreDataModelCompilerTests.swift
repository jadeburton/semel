//
//  CoreDataModelCompilerTests.swift
//  SemelAppleTests
//
//  momc compiles a Core Data model into what an app loads, a `.mom` or a `.momd`, placed
//  in the bundle's resources (B-77 item 4). The walk to every file of the model, the
//  command line, the current version the project names, and the real tool's output being a
//  function of its input.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CoreDataModelCompilerTests: SemelAppleTestCase {

    private let descriptor = ToolDescriptor(name: "momc", version: "Xcode 26.6 (17F113)", platform: "macOS",
                                            architecture: "arm64", recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private static let contents = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <model type="com.apple.IDECoreDataModeler.DataModel" documentVersion="1.0" lastSavedToolsVersion="1" systemVersion="1" \
        minimumToolsVersion="Automatic" sourceLanguage="Objective-C" userDefinedModelVersionIdentifier="">
            <entity name="Note" representedClassName="NoteMO" syncable="YES">
                <attribute name="title" optional="YES" attributeType="String"/>
            </entity>
        </model>
        """

    private func configuration(sdkPath: String = "/SDKs/MacOSX.sdk", currentVersion: String? = nil,
                               omitting omitted: String? = nil) -> String {
        var lines = ["toolDescriptor.name=\(descriptor.name)",
                     "toolDescriptor.version=\(descriptor.version)",
                     "toolDescriptor.platform=\(descriptor.platform)",
                     "toolDescriptor.architecture=\(descriptor.architecture)",
                     "sdkPath=\(sdkPath)",
                     "platform=macosx",
                     "minimumDeploymentTarget=13.5",
                     "module=Sequel_Ace"]
        if let currentVersion {
            lines.append("currentVersion=\(currentVersion)")
        }
        return lines.filter { omitted == nil || !$0.hasPrefix("\(omitted ?? "")=") }.joined(separator: "\n")
    }

    /// An unversioned model, `input:/repo/Model/Store.xcdatamodel` holding `contents`, with
    /// its tree and file arrived unless told otherwise.
    private func processUnversioned(configuration: String? = nil, arrived: Bool = true) throws -> ProcessOutput {
        let model = "input:/repo/Model/Store.xcdatamodel"
        let listing = try manifestValue(model, files: ["contents"])
        let node = try CoreDataModelCompiler(thisNode: NodeRecord(id: 1, kind: CoreDataModelCompiler.kind))
        return try node.process(input: ProcessInput(inputValues: [
            CoreDataModelCompiler.configuration: ["configuration": .value(try (configuration ?? self.configuration()).intern())],
            CoreDataModelCompiler.model:         [model: listing],
            CoreDataModelCompiler.modelTrees:    arrived ? try treeValues(from: [model: listing]) : [:],
            CoreDataModelCompiler.modelFiles:    arrived ? ["\(model)/contents": .value(try Self.contents.intern())] : [:],
        ]))
    }

    /// A model of two versions, `Store 2` current unless told otherwise.
    private func processVersioned(currentVersion: String? = "Store 2.xcdatamodel", sdkPath: String = "/SDKs/MacOSX.sdk") throws -> ProcessOutput {
        let model = "input:/repo/Model/Store.xcdatamodeld"
        let listings = [model: try manifestValue(model, folders: ["Store.xcdatamodel", "Store 2.xcdatamodel"]),
                        "\(model)/Store.xcdatamodel": try manifestValue("\(model)/Store.xcdatamodel", files: ["contents"]),
                        "\(model)/Store 2.xcdatamodel": try manifestValue("\(model)/Store 2.xcdatamodel", files: ["contents"])]
        let node = try CoreDataModelCompiler(thisNode: NodeRecord(id: 1, kind: CoreDataModelCompiler.kind))
        return try node.process(input: ProcessInput(inputValues: [
            CoreDataModelCompiler.configuration: ["configuration": .value(try configuration(sdkPath: sdkPath, currentVersion: currentVersion).intern())],
            CoreDataModelCompiler.model:         [model: try XCTUnwrap(listings[model])],
            CoreDataModelCompiler.modelTrees:    try treeValues(from: listings).filter { $0.key == model },
            CoreDataModelCompiler.modelFiles:    ["\(model)/Store.xcdatamodel/contents": .value(try Self.contents.intern()),
                                                  "\(model)/Store 2.xcdatamodel/contents": .value(try Self.contents.intern())],
        ]))
    }

    // MARK: - Reading the model

    /// Nothing runs until every file of the model has arrived: momc over a model missing a
    /// version would compile a wrong `.momd` without complaint.
    func test_demandsTheModelsTreeAndFilesBeforeRunning() throws {
        let output = try processUnversioned(arrived: false)

        XCTAssertEqual(output.inputWireSpecs[CoreDataModelCompiler.modelTrees]?.keys.sorted(), ["input:/repo/Model/Store.xcdatamodel"])
        XCTAssertTrue(executor.invocations.isEmpty)
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[CoreDataModelCompiler.output]) else {
            return XCTFail("pending until the model is in")
        }
    }

    // MARK: - The run

    /// The model goes into the sandbox under its own name, and momc writes into `out` what
    /// the bundle's resources hold, told the SDK, the deployment target and the module.
    func test_compilesTheModelUnderItsOwnNameForThePlatform() throws {
        executor.producedTrees["out"] = ["Store.mom": Array("mom".utf8)]

        let output = try processUnversioned()

        XCTAssertEqual(executor.lastInputFileNames, ["Store.xcdatamodel/contents"])
        XCTAssertEqual(executor.lastArguments, ["--sdkroot=/SDKs/MacOSX.sdk", "--macosx-deployment-target=13.5",
                                                "--module", "Sequel_Ace", "Store.xcdatamodel", "out/"])
        XCTAssertEqual(try treeManifest(from: output.outputValues[CoreDataModelCompiler.output]).entries.map(\.path), ["Store.mom"])
    }

    /// A versioned model's current version is the project's word for it, written as the
    /// hidden `.xccurrentversion` momc reads, which no push brings.
    func test_aVersionedModelIsToldItsCurrentVersion() throws {
        executor.producedTrees["out"] = ["Store.momd/VersionInfo.plist": Array("plist".utf8)]

        _ = try processVersioned()

        XCTAssertEqual(executor.lastInputFileNames, ["Store.xcdatamodeld/Store 2.xcdatamodel/contents",
                                                     "Store.xcdatamodeld/Store.xcdatamodel/contents",
                                                     "Store.xcdatamodeld/.xccurrentversion"])
        XCTAssertEqual(executor.lastArguments.suffix(2), ["Store.xcdatamodeld", "out/"])
    }

    /// The SDK, the platform and the deployment target are required, and missing is said by
    /// key rather than left to momc's defaults.
    func test_theSDKThePlatformAndTheDeploymentTargetAreRequired() throws {
        for key in ["sdkPath", "platform", "minimumDeploymentTarget"] {
            XCTAssertThrowsError(try processUnversioned(configuration: configuration(omitting: key)), key) { error in
                XCTAssertTrue("\(error)".contains("apple.coreDataModelCompiler.\(key)"), "\(error)")
            }
        }
    }

    /// A clean exit that wrote nothing would place no model in the bundle, and the app would
    /// fail where it loads it.
    func test_aCleanExitThatWroteNothingIsAnError() throws {
        let output = try processUnversioned()

        XCTAssertEqual(output.outputValues[CoreDataModelCompiler.output]?.errorDocument?.diagnostic,
                       .engine(.toolWroteNothing(tool: "momc", status: 0, paths: ["Store.mom"])))
    }

    /// A file momc wrote that names the folder it ran in would differ every run.
    func test_aModelNamingItsSandboxIsRefused() throws {
        executor.producedTrees["out"] = ["Store.mom": Array("/tmp/recording-tool-sandbox/Store.xcdatamodel".utf8)]

        let output = try processUnversioned()

        XCTAssertEqual(output.outputValues[CoreDataModelCompiler.output]?.errorDocument?.diagnostic,
                       .engine(.toolOutputNamesItsSandbox(tool: "momc", file: "Store.mom")))
    }

    // MARK: - The real tool

    /// Two runs of the machine's momc over a versioned model, each in a sandbox of its own,
    /// write the same tree — every `.mom`, the current version's `.omo`, and a
    /// `VersionInfo.plist` naming the version the project made current.
    func test_theRealMomcWritesTheSameModelTwice() throws {
        let momc = try XCTUnwrap(AppleToolDiscovery.locate("momc"))
        let sdkPath = try XCTUnwrap(SemelApple.sdkPath(forPlatform: .macos))
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: try LocalFileSystemTool(localPath: momc))

        let trees = try (0..<2).map { _ in try treeManifest(from: try processVersioned(sdkPath: sdkPath).outputValues[CoreDataModelCompiler.output]) }

        XCTAssertEqual(trees[0].entries.map(\.path), ["Store.momd/Store 2.mom", "Store.momd/Store 2.omo",
                                                      "Store.momd/Store.mom", "Store.momd/VersionInfo.plist"])
        XCTAssertEqual(trees[0].entries.map(\.hash), trees[1].entries.map(\.hash))
        let versionInfo = try XCTUnwrap(trees[0].entries.first { $0.path == "Store.momd/VersionInfo.plist" })
        guard case .file(let hash, _) = versionInfo.content else {
            return XCTFail("VersionInfo.plist is a file")
        }
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(try hash.resolve()), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSManagedObjectModel_CurrentVersionName"] as? String, "Store 2")
    }
}
