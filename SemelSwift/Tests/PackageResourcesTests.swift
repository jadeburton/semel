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

    func test_anExcludedPathIsNotAResource() {
        let rules = PackageResources.Rules(exclude: ["Resources"])
        let found = PackageResources.detect(rules: rules, targetFolder: targetFolder, manifests: foodTruckKit)

        XCTAssertEqual(found.map(\.path), ["Assets.xcassets"])
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

    /// Runs the converter until it stops asking for subfolders, answering each demand from
    /// `manifests`; a folder it asks for that is not there is answered empty.
    private func formula(manifests: [String: FolderManifest]) throws -> String {
        let packageFolder = "input:/pkg"
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        var subfolders: [String: NodeValue] = [:]
        for _ in 0..<6 {
            let output = try converter.process(input: ProcessInput(inputValues: [
                SwiftFormulaConverter.packageFolder:        ["folder": .value(try FolderManifest(baseFolderPath: packageFolder, entries: []).toJSON().intern())],
                SwiftFormulaConverter.packageJSON:          ["json":   .value(try libManifest.intern())],
                SwiftFormulaConverter.externalPackageJSONs: [:],
                SwiftFormulaConverter.targetFolders:        [targetFolder: .value(try XCTUnwrap(manifests[targetFolder]).toJSON().intern())],
                SwiftFormulaConverter.targetSubfolders:     subfolders,
            ]))
            if case .value(let hash) = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]) {
                return try hash.resolveAsString()
            }
            for folder in (output.inputWireSpecs[SwiftFormulaConverter.targetSubfolders] ?? [:]).keys where subfolders[folder] == nil {
                subfolders[folder] = .value(try (manifests[folder] ?? manifest(folder)).toJSON().intern())
            }
        }
        XCTFail("the converter kept asking for subfolders")
        return ""
    }

    /// The target compiles with the accessor's bundle name, its resources become one
    /// bundle under `<Package>_<Target>.bundle/`, and the product carries the bundles
    /// of its targets as one tree an app can name.
    func test_aTargetWithResourcesGetsABundleAndTheProductATreeOfBundles() throws {
        let formula = try formula(manifests: foodTruckKit)

        XCTAssertTrue(formula.contains("resourceBundleName: 'pkg_Lib'"), formula)
        XCTAssertTrue(formula.contains("func bundle_Lib() =\n    TreeMerger(under: 'pkg_Lib.bundle', input: ["), formula)
        XCTAssertTrue(formula.contains("AssetCatalogCompiler(configuration: ['config': Configuration(base: ['settings': ConfigFilter(prefix: 'apple.assetCatalogCompiler'"), formula)
        XCTAssertTrue(formula.contains("catalogs: ['Assets.xcassets': Folder(path: 'input:/pkg/Sources/Lib/Assets.xcassets').manifest]).files"), formula)
        XCTAssertTrue(formula.contains("FolderTreeBuilder(under: 'en.lproj', folder: ['folder': Folder(path: 'input:/pkg/Sources/Lib/Resources/en.lproj').manifest]).files"), formula)
        XCTAssertTrue(formula.contains("func bundles_pkg() =\n    TreeMerger(input: [\n        'Lib': bundle_Lib().files\n    ]).files"), formula)
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
    }

    /// The walk asks for every subfolder that is not a resource whole, and for nothing
    /// inside a catalog or an `.lproj`.
    func test_theConverterWalksSubfoldersButNotResourcesWhole() throws {
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try FolderManifest(baseFolderPath: "input:/pkg", entries: []).toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try libManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
            SwiftFormulaConverter.targetFolders:        [targetFolder: .value(try foodTruckKit[targetFolder]!.toJSON().intern())],
        ]))

        XCTAssertEqual(Set((output.inputWireSpecs[SwiftFormulaConverter.targetSubfolders] ?? [:]).keys),
                       ["\(targetFolder)/Resources", "\(targetFolder)/Views"])
    }
}
