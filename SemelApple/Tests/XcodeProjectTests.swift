//
//  XcodeProjectTests.swift
//  SemelAppleTests
//
//  A project file in the OpenStep form Xcode writes, cut down to what a build reads: one
//  application with a synchronized folder, package products, a framework, an embedded
//  extension, and settings on every layer.
//

@testable import SemelApple
import XCTest

final class XcodeProjectTests: XCTestCase {

    static let fixture = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 77;
            objects = {
                P1 /* Project object */ = {
                    isa = PBXProject;
                    buildConfigurationList = CL1;
                    mainGroup = G1;
                    targets = ( T1, T2 );
                };
                CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1, C2 ); };
                C1 = { isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = XC1;
                       buildSettings = { SWIFT_VERSION = 6.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; }; };
                C2 = { isa = XCBuildConfiguration; name = Release; buildSettings = { SWIFT_VERSION = 6.0; }; };
                XC1 = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = App.xcconfig; sourceTree = "<group>"; };
                G1 = { isa = PBXGroup; children = ( W1, W2 ); sourceTree = "<group>"; };
                W1 = { isa = PBXFileReference; lastKnownFileType = wrapper; name = Timeline; path = Packages/Timeline; sourceTree = "<group>"; };
                W2 = { isa = PBXFileReference; lastKnownFileType = wrapper; name = Models; path = Packages/Models; sourceTree = "<group>"; };
                R1 = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/evgenyneu/keychain-swift"; requirement = { kind = branch; branch = master; }; };
                T1 = {
                    isa = PBXNativeTarget;
                    name = IceCubesApp;
                    productType = "com.apple.product-type.application";
                    productReference = PR1;
                    buildConfigurationList = CL2;
                    buildPhases = ( BP1, BP2, BP3 );
                    fileSystemSynchronizedGroups = ( SG1 );
                    packageProductDependencies = ( PD1, PD2 );
                };
                PR1 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = "Ice Cubes.app"; sourceTree = BUILT_PRODUCTS_DIR; };
                CL2 = { isa = XCConfigurationList; buildConfigurations = ( C3, C4 ); };
                C3 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                    PRODUCT_NAME = "Ice Cubes";
                    PRODUCT_BUNDLE_IDENTIFIER = "$(BUNDLE_ID_PREFIX).IceCubesApp";
                    IPHONEOS_DEPLOYMENT_TARGET = 18.5;
                    SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) EXTRA";
                    "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphonesimulator*]" = YES;
                    "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=macosx*]" = NO;
                    INFOPLIST_FILE = IceCubesApp/Info.plist;
                    ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
                }; };
                C4 = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_NAME = "Ice Cubes"; }; };
                BP1 = { isa = PBXFrameworksBuildPhase; files = ( BF1, BF2 ); };
                BF1 = { isa = PBXBuildFile; fileRef = F1; };
                F1 = { isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = QuickLook.framework; path = System/Library/Frameworks/QuickLook.framework; sourceTree = SDKROOT; };
                BF2 = { isa = PBXBuildFile; productRef = PD1; };
                BP2 = { isa = PBXResourcesBuildPhase; files = ( BF3 ); };
                BF3 = { isa = PBXBuildFile; fileRef = F2; };
                F2 = { isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon; sourceTree = "<group>"; };
                BP3 = { isa = PBXCopyFilesBuildPhase; dstPath = ""; dstSubfolderSpec = 13; files = ( BF4 ); };
                BF4 = { isa = PBXBuildFile; fileRef = PR2; };
                SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = IceCubesApp; exceptions = ( EX1 ); sourceTree = "<group>"; };
                EX1 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( Info.plist, "Embeds/glass.wav" ); target = T1; };
                PD1 = { isa = XCSwiftPackageProductDependency; productName = Timeline; };
                PD2 = { isa = XCSwiftPackageProductDependency; package = R1; productName = KeychainSwift; };
                T2 = {
                    isa = PBXNativeTarget;
                    name = IceCubesShareExtension;
                    productType = "com.apple.product-type.app-extension";
                    productReference = PR2;
                    buildConfigurationList = CL3;
                    buildPhases = ( );
                    fileSystemSynchronizedGroups = ( );
                    packageProductDependencies = ( );
                };
                PR2 = { isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = IceCubesShareExtension.appex; sourceTree = BUILT_PRODUCTS_DIR; };
                CL3 = { isa = XCConfigurationList; buildConfigurations = ( C5 ); };
                C5 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { PRODUCT_NAME = "$(TARGET_NAME)"; }; };
            };
            rootObject = P1;
        }
        """

    private func project() throws -> XcodeProject {
        try XcodeProject(pbxproj: Data(Self.fixture.utf8))
    }

    private func app() throws -> XcodeProject.Target {
        try XCTUnwrap(try project().targets.first { $0.name == "IceCubesApp" })
    }

    // MARK: - Reading the project

    func test_readsTheNativeTargetsWithTheirProductsAndKinds() throws {
        let project = try project()

        XCTAssertEqual(project.targets.map(\.name), ["IceCubesApp", "IceCubesShareExtension"])
        XCTAssertEqual(try app().productFileName, "Ice Cubes.app")
        XCTAssertTrue(try app().isApplication)
        XCTAssertTrue(try XCTUnwrap(project.targets.last).isExtension)
    }

    func test_readsTheSynchronizedFolderAndItsExceptions() throws {
        let folders = try app().synchronizedFolders

        XCTAssertEqual(folders.map(\.path), ["IceCubesApp"])
        XCTAssertEqual(folders.first?.exceptions, ["Embeds/glass.wav", "Info.plist"])
    }

    func test_readsWhatTheTargetLinksAndEmbeds() throws {
        let target = try app()

        XCTAssertEqual(target.packageProducts, [.local(product: "Timeline"),
                                                .remote(product: "KeychainSwift", repositoryURL: "https://github.com/evgenyneu/keychain-swift")])
        XCTAssertEqual(target.frameworks, ["QuickLook"])
        XCTAssertEqual(target.embeddedExtensions, ["IceCubesShareExtension.appex"])
        XCTAssertEqual(target.resourceFiles, ["AppIcon.icon"])
    }

    func test_readsTheLocalAndRemotePackagesTheProjectReferences() throws {
        let project = try project()

        XCTAssertEqual(project.localPackagePaths, ["Packages/Models", "Packages/Timeline"])
        XCTAssertEqual(project.remotePackageURLs, ["https://github.com/evgenyneu/keychain-swift"])
    }

    func test_somethingThatIsNotAProjectIsRefused() {
        XCTAssertThrowsError(try XcodeProject(pbxproj: Data("{ }".utf8)))
    }

    // MARK: - Settings

    private func settings(sdk: String = "iphonesimulator",
                          xcconfig: [String: String] = ["App.xcconfig": "BUNDLE_ID_PREFIX = com.example // mine\nDEVELOPMENT_TEAM = TEAM"],
                          configuration: String = "Debug") throws -> XcodeBuildSettings {
        try XcodeBuildSettings.resolve(project: try project(), target: try app(), configuration: configuration, sdk: sdk,
                                       xcconfig: { xcconfig[$0] }, extra: ["TARGET_NAME": "IceCubesApp"])
    }

    /// Target over project, project over its xcconfig, and `$(inherited)` reaching down.
    func test_layersTheTargetOverTheProjectOverTheXcconfig() throws {
        let settings = try settings()

        XCTAssertEqual(settings["IPHONEOS_DEPLOYMENT_TARGET"], "18.5")
        XCTAssertEqual(settings["SWIFT_VERSION"], "6.0")
        XCTAssertEqual(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DEBUG EXTRA")
    }

    func test_resolvesReferencesAcrossLayers() throws {
        let settings = try settings()

        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.IceCubesApp")
        XCTAssertEqual(settings["PRODUCT_NAME"], "Ice Cubes")
        XCTAssertEqual(settings["PRODUCT_MODULE_NAME"], "Ice_Cubes", "the default module name is the product name as an identifier")
    }

    /// The xcconfig the project names may not exist in a fresh clone; its references then
    /// stay unresolved for the plist builder to report, rather than failing the read.
    func test_aMissingXcconfigIsAnEmptyLayer() throws {
        let settings = try settings(xcconfig: [:])

        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "$(BUNDLE_ID_PREFIX).IceCubesApp")
    }

    func test_aConditionalSettingAppliesForItsSDKOnly() throws {
        XCTAssertEqual(try settings(sdk: "iphonesimulator")["INFOPLIST_KEY_UILaunchScreen_Generation"], "YES")
        XCTAssertEqual(try settings(sdk: "macosx")["INFOPLIST_KEY_UILaunchScreen_Generation"], "NO")
        XCTAssertNil(try settings(sdk: "xros")["INFOPLIST_KEY_UILaunchScreen_Generation"])
    }

    func test_anUnknownConfigurationNamesTheOnesThereAre() {
        XCTAssertThrowsError(try settings(configuration: "Beta")) { error in
            XCTAssertTrue("\(error)".contains("Debug") && "\(error)".contains("Release"), "\(error)")
        }
    }

    /// The real thing, when this machine has it: IceCubesApp's project file, as Xcode
    /// wrote it. Skipped elsewhere; the fixture above is what CI reads.
    func test_readsIceCubesAppsProjectWhenPresent() throws {
        let path = NSString("~/IceCubesApp/IceCubesApp.xcodeproj/project.pbxproj").expandingTildeInPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no IceCubesApp checkout on this machine")

        let project = try XcodeProject(pbxproj: try Data(contentsOf: URL(fileURLWithPath: path)))

        XCTAssertEqual(project.targets.count, 5)
        let app = try XCTUnwrap(project.targets.first { $0.isApplication })
        XCTAssertEqual(app.productFileName, "Ice Cubes.app")
        XCTAssertEqual(app.embeddedExtensions.count, 4)
        XCTAssertEqual(app.synchronizedFolders.map(\.path).sorted(), ["AlternateIcons", "IceCubesApp", "IceCubesAppIntents"])
        XCTAssertEqual(project.localPackagePaths.count, 13)
        XCTAssertEqual(project.remotePackageURLs.count, 4)
        let settings = try XcodeBuildSettings.resolve(project: project, target: app, configuration: "Debug", sdk: "iphonesimulator",
                                                      xcconfig: { _ in "BUNDLE_ID_PREFIX = com.example" },
                                                      extra: ["TARGET_NAME": app.name])
        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.example.IceCubesApp")
        XCTAssertEqual(settings["IPHONEOS_DEPLOYMENT_TARGET"], "18.5")
        XCTAssertEqual(settings["INFOPLIST_KEY_UILaunchScreen_Generation"], "YES")
    }

    func test_parsesXcconfigLines() {
        let parsed = XcodeBuildSettings.parseXcconfig("""
            // comment
            #include "other.xcconfig"
            DEVELOPMENT_TEAM = ABC123 // team
            BUNDLE_ID_PREFIX=com.example
            """)

        XCTAssertEqual(parsed, ["DEVELOPMENT_TEAM": "ABC123", "BUNDLE_ID_PREFIX": "com.example"])
    }
}
