//
//  SequelAceFixtureTests.swift
//  SemelAppleTests
//
//  What Semel makes of Sequel Ace's project (B-77 item 4): `Fixtures/SequelAce` holds its
//  project file and its `SPMySQLFramework` sub-project's, as they are at
//  1f2798da98d7cd8eef5cb5be97ce23de06733202, under its MIT licence. An Objective-C Mac app
//  with Swift beside it, every source listed through groups: what it asks of the emitter
//  is header lookup the way Xcode's header map does it, a prefix header, the Objective-C
//  interface of its Swift, per-file flags, the SDK's libraries and a vendored framework.
//

@testable import SemelApple
import Foundation
import XCTest

final class SequelAceFixtureTests: SemelAppleTestCase {

    static var sequelAce: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/SequelAce", isDirectory: true)
    }

    private static let build = XcodeFormulaEmitter.Build(root: "input:/repo", projectFolder: "input:/repo",
                                                         configuration: "Debug", sdk: "macosx")

    /// The project file as the clone has it.
    private func pbxproj() throws -> String {
        try String(contentsOf: Self.sequelAce.appendingPathComponent("sequel-ace.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    /// The build files a build with no lex and no Core Data model compiler steps around:
    /// the project file with them out of the app's sources phase.
    private static let unbuiltSourcesInPhase = [
        "179F15060F7C433C00579954 /* SPEditorTokens.l in Sources */,",
        "BCD0AD490FBBFC340066EA5C /* SPSQLTokenizer.l in Sources */,",
        "4D90B79E101E0CF200D116A1 /* SPUserManager.xcdatamodel in Sources */,",
    ]

    /// The sub-project the fixture holds; `QueryKit`'s is not there, as a clone that had not
    /// pushed it would not have it.
    static let spMySQLProject = "Frameworks/SPMySQLFramework/SPMySQLFramework.xcodeproj"

    private func spMySQL() throws -> XcodeProject {
        try XcodeProject(pbxproj: try Data(contentsOf: Self.sequelAce.appendingPathComponent("\(Self.spMySQLProject)/project.pbxproj")))
    }

    private func formula(pbxproj text: String,
                         listing: @escaping (String) -> XcodeFormulaEmitter.FolderListing? = { _ in nil }) throws -> String {
        let project = try XcodeProject(pbxproj: Data(text.utf8))
        var emitter = XcodeFormulaEmitter(project: project, build: Self.build, localPackagePaths: [])
        emitter.builtFrameworks = try XcodeProjectConverter.builtFrameworks(
            of: project.targets.flatMap(\.linkedProducts), in: [Self.spMySQLProject: try spMySQL()], build: Self.build)
        let application = try XCTUnwrap(project.applications.first { $0.name == "Sequel Ace" })
        return try emitter.formula(
            for: application,
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: "macosx",
                                               xcconfig: { _ in nil },
                                               extra: ["TARGET_NAME": target.name, "PROJECT_NAME": "sequel-ace"])
            },
            listing: listing)
    }

    /// The app's formula with the lex and Core Data sources stepped around, and the
    /// project's `Frameworks` folder holding what the clone's does.
    private func appFormula() throws -> String {
        var text = try pbxproj()
        for line in Self.unbuiltSourcesInPhase {
            text = text.replacingOccurrences(of: line, with: "")
        }
        return try formula(pbxproj: text) { folder in
            folder == "input:/repo/Frameworks"
                ? .init(files: [], folders: ["QueryKit", "SPMySQLFramework", "ShortcutRecorder.framework", "libmysqlclient"])
                : nil
        }
    }

    private func block(_ opening: String, in formula: String) throws -> String {
        try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix(opening) }, "no block opening \(opening) in\n\(formula)")
    }

    // MARK: - What stops it first

    /// The app's sources phase lists two lex files and a Core Data model, which no node
    /// builds yet: refused by name, rather than left out of a build that would link
    /// without the scanners and launch without the model.
    func test_theLexFilesAndTheCoreDataModelAreRefusedByName() throws {
        XCTAssertThrowsError(try formula(pbxproj: try pbxproj())) { error in
            guard case XcodeProjectError.unsupportedSources(let target, let files) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(target, "Sequel Ace")
            XCTAssertEqual(files, ["Source/Model/CoreData/SPUserManager.xcdatamodel", "Source/Other/Parsing/SPEditorTokens.l",
                                   "Source/Other/Parsing/SPSQLTokenizer.l"])
        }
    }

    // MARK: - Header lookup

    /// Every header the project references is in the app's header map: one tree by path,
    /// whose folders are the preprocessor's `-iquote`s, and — `headerMapProduct` — the
    /// same headers by name under the product. `SPConstants.h` is in `Source/Other/Data`;
    /// every source imports it as `"SPConstants.h"` from wherever it is. The bridging header
    /// is in the tree too: the Swift's Objective-C interface imports it by name.
    func test_theProjectsHeadersAreTheAppsHeaderMap() throws {
        let formula = try appFormula()

        let headers = try block("func headers_Sequel_Ace() =", in: formula)
        XCTAssertTrue(headers.contains("'Source/Other/Data/SPConstants.h': StaticFile(path: 'input:/repo/Source/Other/Data/SPConstants.h').output"),
                      headers)
        XCTAssertTrue(headers.contains("'Source/Sequel-Ace-Bridging-Header.h'"), headers)
        let preprocessor = try block("func preprocess_Sequel_Ace(path) =", in: formula)
        XCTAssertTrue(preprocessor.contains("quoteHeaderTrees: ['input:/repo': headers_Sequel_Ace().files]"), preprocessor)
        XCTAssertTrue(preprocessor.contains("headerMapProduct: 'Sequel Ace'"), preprocessor)
        XCTAssertFalse(preprocessor.contains("headerFolders:"), "a listed source's folder is no search path: \(preprocessor)")
    }

    /// `GCC_PREFIX_HEADER = Source/Sequel-Ace.pch`, set on the project, is forced into
    /// every C-family source: it is what imports Cocoa and `SPConstants.h` for them all.
    func test_thePrefixHeaderIsForcedIntoEverySource() throws {
        let preprocessor = try block("func preprocess_Sequel_Ace(path) =", in: try appFormula())

        XCTAssertTrue(preprocessor.contains("prefixHeader: ['input:/repo/Source/Sequel-Ace.pch': "
                                            + "StaticFile(path: 'input:/repo/Source/Sequel-Ace.pch').output]"), preprocessor)
    }

    /// `SWIFT_OBJC_INTERFACE_HEADER_NAME = $(PROJECT_NAME)-Swift.h`: the Swift compiler
    /// writes `sequel-ace-Swift.h`, which twenty-five of the app's Objective-C sources
    /// import, and every preprocess finds it on an `-I` of its own.
    func test_theSwiftInterfaceIsWrittenUnderTheNameTheSettingsGiveIt() throws {
        let formula = try appFormula()

        XCTAssertTrue(try block("func compiler_Sequel_Ace() =", in: formula).contains("objectiveCHeaderName: 'sequel-ace-Swift.h'"))
        XCTAssertTrue(try block("func preprocess_Sequel_Ace(path) =", in: formula)
            .contains("'derived-headers': TreeBuilder(input: ['sequel-ace-Swift.h': compiler_Sequel_Ace().objectiveCHeader, "
                      + "'Sequel Ace/sequel-ace-Swift.h': compiler_Sequel_Ace().objectiveCHeader]).files"))
    }

    /// `RegexKitLite.m` is built without ARC (`COMPILER_FLAGS = "-fno-objc-arc"` on its
    /// build file), after the target's `-fobjc-arc`, by a preprocessor and a compiler of its
    /// own.
    func test_aListedSourcesOwnFlagsComeAfterTheTargets() throws {
        let formula = try appFormula()

        let entry = try XCTUnwrap(formula.components(separatedBy: "\n").first {
            $0.contains("'input:/repo/Source/ThirdParty/RegexKitLite/RegexKitLite.m.o': ClangCompiler(")
        })
        XCTAssertTrue(entry.contains("arguments: '-fno-objc-arc'"), entry)
        let flagged = try XCTUnwrap(entry.range(of: "preprocess_Sequel_Ace_[0-9]+", options: .regularExpression).map { String(entry[$0]) })
        XCTAssertTrue(try block("func \(flagged)(path) =", in: formula).contains("arguments: '-fno-objc-arc'"))
    }

    // MARK: - What it links

    /// The frameworks phase's SDK libraries are `-l`s, in the phase's order, beside its
    /// SDK frameworks.
    func test_theSDKsLibrariesAreLinkedByName() throws {
        let formula = try appFormula()

        XCTAssertTrue(formula.contains("arguments: '-framework,Cocoa,-framework,Quartz,-framework,QuickLookUI,-framework,Security,"
                                       + "-framework,WebKit,-lc++,-lz,-licucore,-lbz2'"), formula)
    }

    /// `Frameworks/ShortcutRecorder.framework`, prebuilt and in the repository, is compiled
    /// and linked against as the tree it is — its versioned links kept — and embedded by
    /// the copy-files phase under `Contents/Frameworks`. The framework search path that
    /// finds it too adds nothing; the one naming the platform's folder is outside the
    /// project and said to be left out.
    func test_theVendoredFrameworkIsCompiledLinkedAndEmbeddedAsTheTreeItIs() throws {
        let formula = try appFormula()

        let tree = "FolderTreeBuilder(under: 'ShortcutRecorder.framework', "
                 + "folder: ['folder': Folder(path: 'input:/repo/Frameworks/ShortcutRecorder.framework').manifest]).files"
        XCTAssertTrue(try block("func linkedFrameworks_Sequel_Ace() =", in: formula)
            .contains("'Frameworks/ShortcutRecorder.framework': \(tree)"))
        XCTAssertFalse(formula.contains("searchedFrameworks_Sequel_Ace"), formula)
        XCTAssertTrue(try block("func compiler_Sequel_Ace() =", in: formula).contains("'Sequel Ace linked': linkedFrameworks_Sequel_Ace().files"))
        XCTAssertTrue(try block("func preprocess_Sequel_Ace(path) =", in: formula).contains("'Sequel Ace linked': linkedFrameworks_Sequel_Ace().files"))
        XCTAssertTrue(try block("func bundle_Sequel_Ace() =", in: formula).contains("'ShortcutRecorder.framework': \(tree)"))
        XCTAssertTrue(formula.contains("$(PLATFORM_DIR)/Developer/Library/Frameworks"), "said to be left out: \(formula)")
    }

    // MARK: - The framework a referenced project builds

    /// The app links and embeds `SPMySQL.framework` and `QueryKit.framework` through
    /// reference proxies into two projects under `Frameworks/`, and copies its tool
    /// `SequelAceTunnelAssistant` beside its executable; the framework target's headers
    /// phase says which headers are public, and its copy-files phase puts the MySQL client
    /// and OpenSSL beside its executable.
    func test_theProjectReadsWhatOtherProjectsBuildForIt() throws {
        let app = try XCTUnwrap(try XcodeProject(pbxproj: Data(try pbxproj().utf8)).targets.first { $0.name == "Sequel Ace" })

        XCTAssertEqual(app.linkedProducts, [
            .init(projectPath: "Frameworks/QueryKit/QueryKit.xcodeproj", fileName: "QueryKit.framework", targetName: "QueryKit"),
            .init(projectPath: Self.spMySQLProject, fileName: "SPMySQL.framework", targetName: "SPMySQL.framework"),
        ])
        XCTAssertEqual(app.embeddedFrameworks, ["QueryKit.framework", "SPMySQL.framework", "ShortcutRecorder.framework"])
        XCTAssertEqual(app.copiedProducts, ["SequelAceTunnelAssistant"])

        let framework = try XCTUnwrap(try spMySQL().targets.first { $0.name == "SPMySQL.framework" })
        XCTAssertTrue(framework.isFramework)
        XCTAssertEqual(framework.publicHeaders.count, 24)
        XCTAssertTrue(framework.publicHeaders.contains("Source/SPMySQL.h"), "\(framework.publicHeaders)")
        XCTAssertEqual(framework.executableCopies.map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["libcrypto.3.dylib", "libmysqlclient.24.dylib", "libssl.3.dylib"])
        XCTAssertEqual(framework.linkedFiles.sdkLibraries, ["c++", "z"])
    }

    /// `SPMySQL.framework` is built from its project's sources — its Swift importing its
    /// Objective-C as the underlying module, from the framework's public headers and its
    /// module map, and `MySQLClient` from `SWIFT_INCLUDE_PATHS` — linked as a dynamic library
    /// with the install name Xcode gives it, and laid out versioned: `Versions/A` with the
    /// executable, the headers, the module map, the Swift module and the plist, and the
    /// links a Mac framework has at its top.
    func test_theReferencedFrameworkIsBuiltAndLaidOutVersioned() throws {
        let formula = try appFormula()

        let compiler = try block("func compiler_SPMySQL_framework() =", in: formula)
        XCTAssertTrue(compiler.contains("importsUnderlyingModule: 'true'"), compiler)
        XCTAssertTrue(compiler.contains("'SPMySQL': moduleHeaders_SPMySQL_framework().files"), compiler)
        XCTAssertTrue(compiler.contains("inputModuleMapFolders: [\n            'input:/repo/Frameworks/SPMySQLFramework/Source/MySQLClient': "
                                        + "Folder(path: 'input:/repo/Frameworks/SPMySQLFramework/Source/MySQLClient').manifest"), compiler)
        XCTAssertTrue(compiler.contains("includeTrees: [\n            'input:/repo/Frameworks/SPMySQLFramework': headers_SPMySQL_framework().files"),
                      compiler)
        let library = try block("func library_SPMySQL_framework() =", in: formula)
        XCTAssertTrue(library.contains("linkage: 'dynamicLibrary'"), library)
        XCTAssertTrue(library.contains("-Xlinker,-install_name,-Xlinker,@executable_path/../Frameworks/SPMySQL.framework/Versions/A/SPMySQL"),
                      library)
        XCTAssertTrue(library.contains("'MySQL Client Libraries/lib/libmysqlclient.24.dylib': "
                                       + "StaticFile(path: 'input:/repo/Frameworks/SPMySQLFramework/MySQL Client Libraries/lib/libmysqlclient.24.dylib').output"),
                      library)
        let tree = try block("func builtFramework_SPMySQL() =", in: formula)
        for entry in ["'SPMySQL.framework/Versions/A/SPMySQL': library_SPMySQL_framework().output",
                      "'SPMySQL.framework/Versions/A/Headers/SPMySQL.h': StaticFile(",
                      "'SPMySQL.framework/Versions/A/Headers/SPMySQL-Swift.h': compiler_SPMySQL_framework().objectiveCHeader",
                      "'SPMySQL.framework/Versions/A/Modules/module.modulemap': StaticFile(path: 'input:/repo/Frameworks/SPMySQLFramework/Source/SPMySQL.modulemap').output",
                      "'SPMySQL.framework/Versions/A/Modules/SPMySQL.swiftmodule/arm64-apple-macos.swiftmodule': compiler_SPMySQL_framework().swiftmodule",
                      "'SPMySQL.framework/Versions/A/Resources/Info.plist': infoPlist_SPMySQL_framework().plist",
                      "'SPMySQL.framework/Versions/A/libmysqlclient.24.dylib': StaticFile("] {
            XCTAssertTrue(tree.contains(entry), "\(entry) is not in\n\(tree)")
        }
        let links = try XCTUnwrap(tree.range(of: #"links: '[^']*'"#, options: .regularExpression).map { String(tree[$0]) })
        for link in [#""SPMySQL.framework\/Versions\/Current":"A""#, #""SPMySQL.framework\/SPMySQL":"Versions\/Current\/SPMySQL""#,
                     #""SPMySQL.framework\/Headers":"Versions\/Current\/Headers""#, #""SPMySQL.framework\/Modules":"Versions\/Current\/Modules""#,
                     #""SPMySQL.framework\/Resources":"Versions\/Current\/Resources""#] {
            XCTAssertTrue(links.contains(link), "\(link) is not in \(links)")
        }
    }

    /// The app compiles against the framework, links it and embeds it; `QueryKit`, whose
    /// project the fixture does not hold, and the tool copied beside the executable are
    /// said in the formula not to be built.
    func test_theAppCompilesLinksAndEmbedsTheFrameworkItsProjectBuilds() throws {
        let formula = try appFormula()

        XCTAssertTrue(try block("func compiler_Sequel_Ace() =", in: formula).contains("'SPMySQL.framework': builtFramework_SPMySQL().files"))
        XCTAssertTrue(try block("func preprocess_Sequel_Ace(path) =", in: formula).contains("'SPMySQL.framework': builtFramework_SPMySQL().files"))
        XCTAssertTrue(try block("func bundle_Sequel_Ace() =", in: formula).contains("'SPMySQL.framework': builtFramework_SPMySQL().files"))
        XCTAssertTrue(formula.contains("// QueryKit.framework, built by QueryKit in Frameworks/QueryKit/QueryKit.xcodeproj, is linked by Sequel Ace and not built"),
                      formula)
        XCTAssertTrue(formula.contains("// SequelAceTunnelAssistant, a product of this project's own targets, is copied into Sequel Ace"), formula)
    }
}
