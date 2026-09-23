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
                SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = IceCubesApp; exceptions = ( EX1, EX2 ); sourceTree = "<group>"; };
                EX1 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( Info.plist, "Embeds/glass.wav" ); target = T1; };
                EX2 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( "Embeds/glass.wav", "Shared/Entity.swift" ); target = T2; };
                SG2 = { isa = PBXFileSystemSynchronizedRootGroup; path = IceCubesShareExtension; exceptions = ( ); sourceTree = "<group>"; };
                SG3 = { isa = PBXFileSystemSynchronizedRootGroup; path = IceCubesNotifications; exceptions = ( EX3 ); sourceTree = "<group>"; };
                EX3 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( NotificationService.swift ); target = T2; };
                PD1 = { isa = XCSwiftPackageProductDependency; productName = Timeline; };
                PD2 = { isa = XCSwiftPackageProductDependency; package = R1; productName = KeychainSwift; };
                T2 = {
                    isa = PBXNativeTarget;
                    name = IceCubesShareExtension;
                    productType = "com.apple.product-type.app-extension";
                    productReference = PR2;
                    buildConfigurationList = CL3;
                    buildPhases = ( );
                    fileSystemSynchronizedGroups = ( SG2 );
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

    /// The project's Debug configuration is based on an xcconfig; the target's is not, and
    /// Release names none. What `prepare` puts in place and the converter wires are the
    /// same list.
    func test_listsTheXcconfigFilesTheNamedConfigurationIsBasedOn() throws {
        let project = try project()

        XCTAssertEqual(project.xcconfigPaths(for: try app(), configuration: "Debug"), ["App.xcconfig"])
        XCTAssertEqual(project.xcconfigPaths(for: try app(), configuration: "Release"), [])
    }

    func test_theFactsListTheXcconfigFilesOfAProjectOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-xcodeproject-facts-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.fixture.utf8).write(to: project.appendingPathComponent("project.pbxproj"))

        XCTAssertEqual(try XcodeProjectFacts.xcconfigPaths(ofProjectAt: project), ["App.xcconfig"])
    }

    /// An exception set in a folder naming another target says what that target takes
    /// from here; for the folder's own target it says what to leave out. The two must not
    /// be confused: the app's exceptions stay its own, and the extension borrows.
    func test_readsWhatATargetBorrowsFromAnotherTargetsFolder() throws {
        let project = try project()
        let share = try XCTUnwrap(project.targets.first { $0.name == "IceCubesShareExtension" })

        XCTAssertEqual(share.borrowedFiles, ["IceCubesApp/Embeds/glass.wav", "IceCubesApp/Shared/Entity.swift",
                                             "IceCubesNotifications/NotificationService.swift"],
                       "from another target's folder and from a folder no target owns alike")
        XCTAssertEqual(share.synchronizedFolders.map(\.path), ["IceCubesShareExtension"])
        XCTAssertEqual(try app().synchronizedFolders.first?.exceptions, ["Embeds/glass.wav", "Info.plist"])
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

    /// What a reference that resolved to nothing names, so `prepare` can say what a
    /// missing xcconfig would have to define. A name Xcode provides itself is not one.
    func test_namesTheReferencesLeftUnresolved() throws {
        XCTAssertEqual(try settings(xcconfig: [:]).unresolvedReferences, ["BUNDLE_ID_PREFIX"])
        XCTAssertEqual(try settings().unresolvedReferences, [])
        XCTAssertEqual(XcodeBuildSettings.unresolvedReferences(in: ["A": "$(SRCROOT)/x $(MISSING) ${ALSO:rfc1034identifier}"]),
                       ["ALSO", "MISSING"])
    }

    func test_theFactsNameTheUndefinedReferencesOfAProjectOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-xcodeproject-facts-\(UUID().uuidString)")
        let project = folder.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.fixture.utf8).write(to: project.appendingPathComponent("project.pbxproj"))

        XCTAssertEqual(try XcodeProjectFacts.undefinedReferences(ofProjectAt: project, sdk: "iphonesimulator"), ["BUNDLE_ID_PREFIX"])
        try "BUNDLE_ID_PREFIX = com.example\n".write(to: folder.appendingPathComponent("App.xcconfig"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XcodeProjectFacts.undefinedReferences(ofProjectAt: project, sdk: "iphonesimulator"), [])
    }

    /// `PRODUCT_MODULE_NAME` names `PRODUCT_NAME`, which names `TARGET_NAME`: the chain
    /// must resolve regardless of which of the three a `Dictionary` visits first.
    func test_resolvesAChainOfReferencesRegardlessOfDictionaryOrder() throws {
        let extensionTarget = try XCTUnwrap(try project().targets.first { $0.name == "IceCubesShareExtension" })
        let settings = try XcodeBuildSettings.resolve(project: try project(), target: extensionTarget, configuration: "Debug",
                                                       sdk: "iphonesimulator", xcconfig: { _ in nil },
                                                       extra: ["TARGET_NAME": "IceCubesNotifications"])

        XCTAssertEqual(settings["PRODUCT_MODULE_NAME"], "IceCubesNotifications")
    }

    /// The same chain under names whose alphabetical order is the wrong order to visit
    /// them in, so a fixed-point loop that walks a sorted snapshot fails deterministically
    /// rather than by luck: `A_MODULE` must not be substituted before `B_NAME` is.
    func test_resolvesAChainOfReferencesEvenWhenSortedOrderIsTheWrongOrder() throws {
        let settings = try XcodeBuildSettings.resolve(project: try project(), target: try app(), configuration: "Debug",
                                                       sdk: "iphonesimulator", xcconfig: { _ in nil },
                                                       extra: ["TARGET_NAME": "IceCubesApp",
                                                               "A_MODULE": "$(B_NAME:c99extidentifier)",
                                                               "B_NAME": "$(C_TARGET)",
                                                               "C_TARGET": "Foo"])

        XCTAssertEqual(settings["A_MODULE"], "Foo")
    }

    /// A reference cycle has no principled resolution; the resolver must not hang trying
    /// to find one, and must leave the two settings as they are rather than guess.
    func test_aReferenceCycleLeavesBothSettingsUnresolvedAndDoesNotHang() throws {
        let settings = try XcodeBuildSettings.resolve(project: try project(), target: try app(), configuration: "Debug",
                                                       sdk: "iphonesimulator", xcconfig: { _ in nil },
                                                       extra: ["TARGET_NAME": "IceCubesApp",
                                                               "CYCLE_A": "$(CYCLE_B)",
                                                               "CYCLE_B": "$(CYCLE_A)"])

        XCTAssertTrue(settings["CYCLE_A"]?.contains("$") == true)
        XCTAssertTrue(settings["CYCLE_B"]?.contains("$") == true)
    }

    /// An operator applies to the fully resolved value its reference names, not to
    /// whatever that reference's own text happens to be at the time.
    func test_anOperatorAppliesToTheFullyResolvedReferencedValue() throws {
        let settings = try XcodeBuildSettings.resolve(project: try project(), target: try app(), configuration: "Debug",
                                                       sdk: "iphonesimulator", xcconfig: { _ in nil },
                                                       extra: ["TARGET_NAME": "IceCubesApp",
                                                               "OP_X": "$(OP_Y:rfc1034identifier)",
                                                               "OP_Y": "$(OP_Z)",
                                                               "OP_Z": "a b"])

        XCTAssertEqual(settings["OP_X"], "a-b")
    }

    func test_aConditionalSettingAppliesForItsSDKOnly() throws {
        XCTAssertEqual(try settings(sdk: "iphonesimulator")["INFOPLIST_KEY_UILaunchScreen_Generation"], "YES")
        XCTAssertEqual(try settings(sdk: "macosx")["INFOPLIST_KEY_UILaunchScreen_Generation"], "NO")
        XCTAssertNil(try settings(sdk: "xros")["INFOPLIST_KEY_UILaunchScreen_Generation"])
    }

    /// Two conditions on one key can both match the SDK being built for. Which of them
    /// wins must not depend on `Dictionary`'s iteration order, which is seeded per
    /// process: the condition sorting last takes the key, the same way on every run, and
    /// that is the more specific one for the `iphone*` / `iphonesimulator*` pair projects
    /// actually write.
    func test_twoConditionsMatchingOneKeyResolveTheSameWayOnEveryRun() throws {
        var extra = ["TARGET_NAME": "IceCubesApp"]
        for index in 1...6 {
            extra["PAIR_\(index)[sdk=iphone*]"] = "broad"
            extra["PAIR_\(index)[sdk=iphonesimulator*]"] = "specific"
        }

        let settings = try XcodeBuildSettings.resolve(project: try project(), target: try app(), configuration: "Debug",
                                                      sdk: "iphonesimulator", xcconfig: { _ in nil }, extra: extra)

        for index in 1...6 {
            XCTAssertEqual(settings["PAIR_\(index)"], "specific")
        }
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
