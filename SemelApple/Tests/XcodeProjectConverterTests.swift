//
//  XcodeProjectConverterTests.swift
//  SemelAppleTests
//
//  The node's own work is the waiting: the project file a pass after creation, then the
//  xcconfig files it names and the folders it walks, and only then the formula.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class XcodeProjectConverterTests: SemelAppleTestCase {

    private let projectPath = "input:/repo/IceCubesApp.xcodeproj"
    private var projectFile: String { "\(projectPath)/project.pbxproj" }

    private func process(projectFile: NodeValue? = nil,
                         xcconfigs: [String: NodeValue] = [:],
                         folders: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": projectPath], scheduled: false, identity: nil))
        var inputs: [String: [String: NodeValue]] = [XcodeProjectConverter.xcconfigs: xcconfigs,
                                                     XcodeProjectConverter.folders: folders]
        if let projectFile {
            inputs[XcodeProjectConverter.projectFile] = [self.projectFile: projectFile]
        }
        return try node.process(input: ProcessInput(inputValues: inputs))
    }

    private var fixtureProject: NodeValue {
        get throws { .value(try XcodeProjectTests.fixture.intern()) }
    }

    private func isPending(_ output: ProcessOutput) -> Bool {
        if case .noValue(.pending) = output.outputValues[XcodeProjectConverter.formulaOutput] ?? .noValue(reason: .pending) {
            return true
        }
        return false
    }

    func test_demandsTheProjectFileFirst() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.projectFile],
                       [projectFile: "StaticFile(path: '\(projectFile)').output"])
        XCTAssertTrue(isPending(output))
    }

    /// With the project read, the xcconfig it names and the application's folder are
    /// demanded together; the formula waits for both.
    func test_demandsTheXcconfigAndTheTargetFolderOnceTheProjectHasArrived() throws {
        let output = try process(projectFile: try fixtureProject)

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.xcconfigs],
                       ["input:/repo/App.xcconfig": "StaticFile(path: 'input:/repo/App.xcconfig').output"])
        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.folders],
                       ["input:/repo/IceCubesApp": "Folder(path: 'input:/repo/IceCubesApp').manifest",
                        "input:/repo/IceCubesShareExtension": "Folder(path: 'input:/repo/IceCubesShareExtension').manifest"],
                       "the embedded extension's folder is walked too")
        XCTAssertTrue(isPending(output))
    }

    private var extensionFolder: (String, NodeValue) {
        get throws { ("input:/repo/IceCubesShareExtension", try manifestValue("input:/repo/IceCubesShareExtension", files: ["Share.swift"])) }
    }

    /// The folder is walked one level per pass, like every folder walk, except into a
    /// catalog, which its own compiler walks.
    func test_walksSubfoldersButNotCatalogs() throws {
        let output = try process(projectFile: try fixtureProject,
                                 xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
                                 folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                                         files: ["App.swift"],
                                                                                         folders: ["Views", "Assets.xcassets"])])

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.folders]?.keys.sorted(),
                       ["input:/repo/IceCubesApp", "input:/repo/IceCubesApp/Views", "input:/repo/IceCubesShareExtension"])
        XCTAssertTrue(isPending(output))
    }

    /// Everything there: the formula names the executable, the catalog, the plain
    /// resource under the walked subfolder, and the bundle — with the xcconfig's value
    /// resolved into the bundle identifier.
    func test_emitsTheFormulaOnceTheWalkIsComplete() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .value(try "BUNDLE_ID_PREFIX = com.example".intern())],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                    files: ["App.swift", "Info.plist"],
                                                                    folders: ["Fonts", "Assets.xcassets"]),
                      "input:/repo/IceCubesApp/Fonts": try manifestValue("input:/repo/IceCubesApp/Fonts", files: ["Mono.ttf"]),
                      try extensionFolder.0: try extensionFolder.1])

        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Ice Cubes' ="), formula)
        XCTAssertTrue(formula.contains("'Assets.xcassets': Folder(path: 'input:/repo/IceCubesApp/Assets.xcassets').manifest"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Mono.ttf' = StaticFile(path: 'input:/repo/IceCubesApp/Fonts/Mono.ttf').output"), formula)
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"com.example.IceCubesApp\""), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/' = TreeMerger("), formula)
    }

    /// The xcconfig a fresh clone lacks is an empty layer, not a stall: the formula is
    /// emitted with the reference unresolved for the plist builder to report.
    func test_aMissingXcconfigDoesNotStallTheConversion() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"$(BUNDLE_ID_PREFIX).IceCubesApp\""), formula)
    }

    /// The empty layer still builds, but the converter names the cause once, as an error
    /// on `infoLog`, so it reaches the idle error report instead of surfacing only as
    /// eleven unrelated Info.plist failures.
    func test_reportsTheMissingXcconfigAsTheCauseOfTheUndefinedSettings() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        // The empty-layer behaviour holds: the formula is still produced.
        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .noValue(.error(let messageHash)) = infoLog else {
            XCTFail("expected infoLog to carry the cause as an error, got \(infoLog)")
            return
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("input:/repo/App.xcconfig is missing"), message)
        XCTAssertTrue(message.contains("BUNDLE_ID_PREFIX"), message)
    }

    /// Nothing to say about a cause that is not there: an xcconfig that is present leaves
    /// `infoLog` as the ordinary success message.
    func test_doesNotReportAMissingXcconfigWhenItIsPresent() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .value(try "BUNDLE_ID_PREFIX = com.example".intern())],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                    files: ["App.swift", "Info.plist"],
                                                                    folders: ["Fonts", "Assets.xcassets"]),
                      "input:/repo/IceCubesApp/Fonts": try manifestValue("input:/repo/IceCubesApp/Fonts", files: ["Mono.ttf"]),
                      try extensionFolder.0: try extensionFolder.1])

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .value(let hash) = infoLog else {
            XCTFail("expected infoLog to carry the ordinary success message, got \(infoLog)")
            return
        }
        XCTAssertTrue(try hash.resolveAsString().contains("converted"), "should be the success message")
    }

    /// A project whose application target references nothing from its `.xcconfig`: the
    /// file being missing does not undefine anything, so it is not a broken build.
    private var fixtureProjectWithNothingReferenced: NodeValue {
        get throws {
            .value(try """
                // !$*UTF8*$!
                {
                    archiveVersion = 1;
                    objectVersion = 77;
                    objects = {
                        P1 = { isa = PBXProject; buildConfigurationList = CL1; targets = ( T1 ); };
                        CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1 ); };
                        C1 = { isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = XC1; buildSettings = { }; };
                        XC1 = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = App.xcconfig; sourceTree = "<group>"; };
                        T1 = {
                            isa = PBXNativeTarget;
                            name = App;
                            productType = "com.apple.product-type.application";
                            productReference = PR1;
                            buildConfigurationList = CL2;
                            buildPhases = ( );
                            fileSystemSynchronizedGroups = ( SG1 );
                            packageProductDependencies = ( );
                        };
                        SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; exceptions = ( ); sourceTree = "<group>"; };
                        PR1 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = "App.app"; sourceTree = BUILT_PRODUCTS_DIR; };
                        CL2 = { isa = XCConfigurationList; buildConfigurations = ( C2 ); };
                        C2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                            PRODUCT_NAME = App;
                            PRODUCT_BUNDLE_IDENTIFIER = "com.example.App";
                        }; };
                    };
                    rootObject = P1;
                }
                """.intern())
        }
    }

    /// A missing xcconfig that nothing referenced is not a cause of anything: the build is
    /// not broken, so `infoLog` stays the ordinary success value, only noting the file by
    /// way of explanation rather than raising it as an error.
    func test_doesNotErrorWhenTheMissingXcconfigDefinesNothingReferenced() throws {
        let output = try process(
            projectFile: try fixtureProjectWithNothingReferenced,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
            folders: ["input:/repo/App": try manifestValue("input:/repo/App", files: ["App.swift"])])

        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .value(let hash) = infoLog else {
            XCTFail("a missing xcconfig nothing referenced should not be an error, got \(infoLog)")
            return
        }
        let message = try hash.resolveAsString()
        XCTAssertTrue(message.contains("input:/repo/App.xcconfig is missing"), message)
    }
}
