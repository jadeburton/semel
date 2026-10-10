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

    private func formula(pbxproj text: String,
                         listing: @escaping (String) -> XcodeFormulaEmitter.FolderListing? = { _ in nil }) throws -> String {
        let project = try XcodeProject(pbxproj: Data(text.utf8))
        let emitter = XcodeFormulaEmitter(project: project, build: Self.build, localPackagePaths: [])
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
    /// whose folders are the preprocessor's `-iquote`s, and the same headers by name under
    /// the product. `SPConstants.h` is in `Source/Other/Data`; every source imports it as
    /// `"SPConstants.h"` from wherever it is.
    func test_theProjectsHeadersAreTheAppsHeaderMap() throws {
        let formula = try appFormula()

        let headers = try block("func headers_Sequel_Ace() =", in: formula)
        XCTAssertTrue(headers.contains("'Source/Other/Data/SPConstants.h': StaticFile(path: 'input:/repo/Source/Other/Data/SPConstants.h').output"),
                      headers)
        XCTAssertFalse(headers.contains("Sequel-Ace-Bridging-Header.h"), "the bridging header goes by itself: \(headers)")
        let byName = try block("func targetHeaders_Sequel_Ace() =", in: formula)
        XCTAssertTrue(byName.contains("'Sequel Ace/SPConstants.h': StaticFile(path: 'input:/repo/Source/Other/Data/SPConstants.h').output"),
                      byName)
        let preprocessor = try block("func preprocess_Sequel_Ace(path) =", in: formula)
        XCTAssertTrue(preprocessor.contains("quoteHeaderTrees: ['input:/repo': headers_Sequel_Ace().files]"), preprocessor)
        XCTAssertTrue(preprocessor.contains("'target-headers': targetHeaders_Sequel_Ace().files"), preprocessor)
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
            .contains("'derived-headers': TreeBuilder(input: ['sequel-ace-Swift.h': compiler_Sequel_Ace().objectiveCHeader]).files"))
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
}
