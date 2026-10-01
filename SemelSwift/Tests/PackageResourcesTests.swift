//
//  PackageResourcesTests.swift
//  SemelSwiftTests
//
//  B-77. What a target carries besides sources, read by SwiftPM's rules from the folder
//  tree the converter walked, and how the converter turns it into a bundle.
//

@testable import SemelSwift
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class PackageResourcesTests: SemelSwiftTestCase {

    private let targetFolder = "input:/pkg/Sources/Lib"

    private func manifest(_ folder: String, files: [String] = [], folders: [String] = []) -> FolderManifest {
        FolderManifest(baseFolderPath: folder,
                       entries: files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                              + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) })
    }

    /// FoodTruckKit's shape: a catalog at the top, `.lproj` folders under a plain
    /// `Resources` folder, nothing declared. Every one is found by type, wherever it sits.
    private var foodTruckKit: [String: FolderManifest] {
        [targetFolder:                  manifest(targetFolder, files: ["Kit.swift"], folders: ["Assets.xcassets", "Resources", "Views"]),
         "\(targetFolder)/Resources":   manifest("\(targetFolder)/Resources", folders: ["en.lproj", "ar.lproj"]),
         "\(targetFolder)/Views":       manifest("\(targetFolder)/Views", files: ["View.swift"])]
    }

    func test_findsCatalogsAndLocalizedFoldersByTypeAtAnyDepth() {
        let found = PackageResources.detect(rules: .init(), targetFolder: targetFolder, manifests: foodTruckKit)

        XCTAssertEqual(found, [
            PackageResource(kind: .assetCatalog, path: "Assets.xcassets", bundlePath: ""),
            PackageResource(kind: .localizedFolder, path: "Resources/ar.lproj", bundlePath: "ar.lproj"),
            PackageResource(kind: .localizedFolder, path: "Resources/en.lproj", bundlePath: "en.lproj"),
        ])
    }

    /// A copied folder keeps its shape under its name; a processed folder is flattened to
    /// the bundle's root, its recognised types handed to their compilers; a processed
    /// single file lands by name.
    func test_appliesTheManifestsCopyAndProcessRules() {
        let manifests: [String: FolderManifest] = [
            targetFolder:                     manifest(targetFolder, files: ["Kit.swift", "config.json"], folders: ["Data", "Media"]),
            "\(targetFolder)/Data":           manifest("\(targetFolder)/Data", files: ["cities.csv"], folders: ["More"]),
            "\(targetFolder)/Data/More":      manifest("\(targetFolder)/Data/More", files: ["deep.txt"]),
            "\(targetFolder)/Media":          manifest("\(targetFolder)/Media", files: ["Localizable.xcstrings", "sound.wav"], folders: ["Icons.xcassets"]),
        ]
        let rules = PackageResources.Rules(declared: [.init(path: "Data", isCopy: true),
                                                      .init(path: "Media", isCopy: false),
                                                      .init(path: "config.json", isCopy: false)])
        let found = PackageResources.detect(rules: rules, targetFolder: targetFolder, manifests: manifests)

        XCTAssertEqual(found, [
            PackageResource(kind: .folder, path: "Data", bundlePath: "Data"),
            PackageResource(kind: .assetCatalog, path: "Media/Icons.xcassets", bundlePath: ""),
            PackageResource(kind: .stringCatalog, path: "Media/Localizable.xcstrings", bundlePath: ""),
            PackageResource(kind: .file, path: "Media/sound.wav", bundlePath: "sound.wav"),
            PackageResource(kind: .file, path: "config.json", bundlePath: "config.json"),
        ])
    }

    /// RSCore's `RSCoreResources` shape: two xibs at the target's top, nothing declared.
    /// A xib or a storyboard is a resource by type, which SwiftPM compiles; a `.copy`
    /// keeps one as the document it is; a nib is copied, being compiled already.
    func test_findsInterfaceBuilderDocumentsByTypeForIBTool() {
        let manifests: [String: FolderManifest] = [
            targetFolder:             manifest(targetFolder, files: ["Resources.swift", "WebViewWindow.xib", "Legacy.nib"], folders: ["Windows"]),
            "\(targetFolder)/Windows": manifest("\(targetFolder)/Windows", files: ["IndeterminateProgressWindow.xib", "Main.storyboard", "Kept.xib"]),
        ]
        let rules = PackageResources.Rules(declared: [.init(path: "Windows/Kept.xib", isCopy: true)])
        let found = PackageResources.detect(rules: rules, targetFolder: targetFolder, manifests: manifests)

        XCTAssertEqual(found, [
            PackageResource(kind: .file, path: "Legacy.nib", bundlePath: "Legacy.nib"),
            PackageResource(kind: .interfaceBuilder, path: "WebViewWindow.xib", bundlePath: "WebViewWindow.xib"),
            PackageResource(kind: .interfaceBuilder, path: "Windows/IndeterminateProgressWindow.xib", bundlePath: "IndeterminateProgressWindow.xib"),
            PackageResource(kind: .file, path: "Windows/Kept.xib", bundlePath: "Kept.xib"),
            PackageResource(kind: .interfaceBuilder, path: "Windows/Main.storyboard", bundlePath: "Main.storyboard"),
        ])
    }

    func test_anExcludedPathIsNotAResource() {
        let rules = PackageResources.Rules(exclude: ["Resources"])
        let found = PackageResources.detect(rules: rules, targetFolder: targetFolder, manifests: foodTruckKit)

        XCTAssertEqual(found.map(\.path), ["Assets.xcassets"])
    }

    /// purchases-ios declares `.copy("../Sources/PrivacyInfo.xcprivacy")` from a target at
    /// `Sources`: the rule is kept as declared, and where the file is has the `..`
    /// resolved, so the formula never names a folder called `..` — which the engine would
    /// make, with a file in it nothing could push (B-125).
    func test_aDeclaredResourceWithAParentSegmentIsFoundWhereItResolves() {
        let sources = "input:/pkg/Sources"
        let manifests = [sources:            manifest(sources, files: ["Lib.swift", "PrivacyInfo.xcprivacy"], folders: ["Shared"]),
                         "\(sources)/Shared": manifest("\(sources)/Shared", files: ["a.json"])]
        let rules = PackageResources.Rules(declared: [.init(path: "../Sources/PrivacyInfo.xcprivacy", isCopy: true),
                                                      .init(path: "Shared/../Shared", isCopy: true)])
        let found = PackageResources.detect(rules: rules, targetFolder: sources, manifests: manifests)

        XCTAssertEqual(found, [
            PackageResource(kind: .file, path: "../Sources/PrivacyInfo.xcprivacy", bundlePath: "PrivacyInfo.xcprivacy"),
            PackageResource(kind: .folder, path: "Shared/../Shared", bundlePath: "Shared"),
        ])
        XCTAssertEqual(PackageResources.fullPath(targetFolder: sources, relative: "../Sources/PrivacyInfo.xcprivacy"),
                       "input:/pkg/Sources/PrivacyInfo.xcprivacy")
        XCTAssertEqual(PackageResources.fullPath(targetFolder: sources, relative: "../../../above"),
                       "input:/pkg/Sources/../../../above", "a path above the file system is left for the report to show")
    }

    func test_aFolderThatIsAResourceWholeIsNotWalked() {
        XCTAssertFalse(PackageResources.isWalked(folderName: "Assets.xcassets"))
        XCTAssertFalse(PackageResources.isWalked(folderName: "en.lproj"))
        XCTAssertFalse(PackageResources.isWalked(folderName: ".build"))
        XCTAssertTrue(PackageResources.isWalked(folderName: "Resources"))
    }

    // MARK: - The converter

    private let libManifest = """
        {
          "name": "pkg",
          "dependencies": [],
          "products": [{"name": "pkg", "targets": ["Lib"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": [], "resources": []}]
        }
        """

    /// The target folder's tree, folded from `manifests`: a folder they do not list holds
    /// nothing.
    private func targetTree(_ manifests: [String: FolderManifest]) throws -> NodeValue {
        .value(try FolderSubtreeManifest.folding(at: targetFolder, listings: manifests.mapValues(\.entries)).toJSON().intern())
    }

    /// Runs the converter once, with the target folder's tree folded from `manifests`: the
    /// tree is every folder below the target, so the pass that has it makes the formula.
    private func formula(manifests: [String: FolderManifest], packageManifest: String? = nil) throws -> String {
        let packageFolder = "input:/pkg"
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try FolderManifest(baseFolderPath: packageFolder, entries: []).toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try (packageManifest ?? libManifest).intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
            SwiftFormulaConverter.targetFolders:        [targetFolder: try targetTree(manifests)],
        ]))
        guard case .value(let hash) = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]) else {
            XCTFail("the pass with the target's tree made no formula: \(String(describing: output.outputValues[SwiftFormulaConverter.formulaOutput]))")
            return ""
        }
        return try hash.resolveAsString()
    }

    /// The target compiles with the accessor's bundle name, its resources become one
    /// bundle under `<Package>_<Target>.bundle/`, and the product carries the bundles
    /// of its targets as one tree an app can name.
    func test_aTargetWithResourcesGetsABundleAndTheProductATreeOfBundles() throws {
        let formula = try formula(manifests: foodTruckKit)

        XCTAssertTrue(formula.contains("resourceBundleName: 'pkg_Lib'"), formula)
        XCTAssertTrue(formula.contains("func bundleContents_Lib() =\n    TreeMerger(input: ["), formula)
        XCTAssertTrue(formula.contains("func bundle_Lib() =\n    TreeMerger(under: 'pkg_Lib.bundle', input: ['contents': bundleContents_Lib().files]).files"),
                      formula)
        XCTAssertTrue(formula.contains("AssetCatalogCompiler(configuration: ['config': ConfigFilter(prefix: 'apple.assetCatalogCompiler'"), formula)
        XCTAssertTrue(formula.contains("catalogs: ['Assets.xcassets': Folder(path: 'input:/pkg/Sources/Lib/Assets.xcassets').manifest]).files"), formula)
        XCTAssertTrue(formula.contains("FolderTreeBuilder(under: 'en.lproj', folder: ['folder': Folder(path: 'input:/pkg/Sources/Lib/Resources/en.lproj').manifest]).files"), formula)
        XCTAssertTrue(formula.contains("func bundles_pkg() =\n    TreeMerger(input: [\n        'Lib': bundle_Lib().files\n    ]).files"), formula)
    }

    /// A xib is compiled by ibtool into the target's bundle, keyed by where it lands —
    /// flattened, as a processed file is — with the platform's settings from the root's
    /// config and the target's module for the classes it names (B-77 map item 17).
    func test_aXibIsCompiledIntoTheBundleByIBTool() throws {
        let rsCoreResources = [targetFolder: manifest(targetFolder, files: ["Resources.swift"], folders: ["Windows"]),
                               "\(targetFolder)/Windows": manifest("\(targetFolder)/Windows", files: ["WebViewWindow.xib"])]
        let formula = try formula(manifests: rsCoreResources)

        XCTAssertTrue(formula.contains("func bundleContents_Lib() =\n    TreeMerger(input: ["), formula)
        XCTAssertTrue(formula.contains("IBToolCompiler(configuration: ['config': ConfigMerger(base: ['settings': ConfigFilter(prefix: 'apple.ibToolCompiler'"),
                      formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(module: 'Lib').output"), formula)
        XCTAssertTrue(formula.contains("document: ['WebViewWindow.xib': StaticFile(path: 'input:/pkg/Sources/Lib/Windows/WebViewWindow.xib').output]).files"),
                      formula)
        XCTAssertFalse(formula.contains("'WebViewWindow.xib': StaticFile(path: 'input:/pkg/Sources/Lib/Windows/WebViewWindow.xib').output\n"),
                       "compiled, not copied: \(formula)")
    }

    /// The bundle names the copied file where it is, not through a `..` (B-125).
    func test_aCopiedResourceDeclaredThroughAParentSegmentIsNamedWhereItIs() throws {
        let declaring = libManifest.replacingOccurrences(of: "\"resources\": []",
                                                         with: "\"resources\": [{\"path\": \"../Lib/PrivacyInfo.xcprivacy\", \"rule\": {\"copy\": {}}}]")
        let plain = [targetFolder: manifest(targetFolder, files: ["Kit.swift", "PrivacyInfo.xcprivacy"])]
        let formula = try formula(manifests: plain, packageManifest: declaring)

        XCTAssertTrue(formula.contains("'PrivacyInfo.xcprivacy': StaticFile(path: 'input:/pkg/Sources/Lib/PrivacyInfo.xcprivacy').output"), formula)
        XCTAssertFalse(formula.contains("/../"), formula)
    }

    /// A target without resources compiles as before, and its product still names an
    /// empty tree of bundles, so a consumer needs no knowledge to ask.
    func test_aTargetWithoutResourcesStillHasAnEmptyTreeOfBundles() throws {
        let plain = [targetFolder: manifest(targetFolder, files: ["Kit.swift"], folders: ["Views"]),
                     "\(targetFolder)/Views": manifest("\(targetFolder)/Views", files: ["View.swift"])]
        let formula = try formula(manifests: plain)

        XCTAssertFalse(formula.contains("resourceBundleName"), formula)
        XCTAssertFalse(formula.contains("func bundle_Lib()"), formula)
        XCTAssertTrue(formula.contains("func bundles_pkg() =\n    TreeMerger(input: []).files"), formula)
        XCTAssertTrue(formula.contains("func macBundles_pkg() =\n    TreeMerger(input: []).files"), formula)
    }

    /// The tree is read into every subfolder that is not a resource whole, and not into a
    /// catalog or an `.lproj`: what is below one is never read, so a subtree the store
    /// cannot give back there changes nothing (B-135). The one demand is the target's tree.
    func test_theConverterReadsSubfoldersButNotResourcesWhole() throws {
        let unreadable = String(repeating: "0", count: 64)
        let tree = FolderSubtreeManifest(entries: [
            FolderSubtreeEntry(name: "Kit.swift", isFolder: false, isPinned: true),
            FolderSubtreeEntry(name: "Assets.xcassets", isFolder: true, isPinned: true, subtree: unreadable),
            FolderSubtreeEntry(name: "en.lproj", isFolder: true, isPinned: true, subtree: unreadable),
            FolderSubtreeEntry(name: "Views", isFolder: true, isPinned: true,
                               subtree: try FolderSubtreeManifest(entries: [FolderSubtreeEntry(name: "View.swift", isFolder: false, isPinned: true)])
                                   .toJSON().intern()),
        ])
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try FolderManifest(baseFolderPath: "input:/pkg", entries: []).toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try libManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
            SwiftFormulaConverter.targetFolders:        [targetFolder: .value(try tree.toJSON().intern())],
        ]))

        let formula = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("catalogs: ['Assets.xcassets': Folder(path: 'input:/pkg/Sources/Lib/Assets.xcassets').manifest]"), formula)
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]).rendered,
                       [targetFolder: "Folder(path: '\(targetFolder)').subtreeManifest"])
    }
}
