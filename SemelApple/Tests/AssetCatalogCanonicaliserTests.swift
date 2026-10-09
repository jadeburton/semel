//
//  AssetCatalogCanonicaliserTests.swift
//  SemelAppleTests
//
//  actool writes a catalog differently from one compile to the next (B-89). These hold the
//  canonicaliser to real files: two compiles of IceCubes' widgets catalog that differ in
//  which block each appearance name got, and a small Icon Composer icon compiled here by
//  the real actool, whose rendition names differ every time and whose facet names one of
//  two parts. Every canonical file is checked by the real `assetutil`.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class AssetCatalogCanonicaliserTests: SemelAppleTestCase {

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/AssetCatalogs", isDirectory: true)
    }

    /// IceCubesApp's widgets catalog at 3dc60a80, two colour sets with light and dark
    /// appearances and an icon set, compiled twice by actool 26.6 for the simulator: the
    /// two files differ in 16 bytes, the appearance names in each other's blocks.
    static func widgetsCatalog(_ compile: Int) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("IceCubesWidgets-\(compile).car")))
    }

    private func catalogGuard() throws -> AssetCatalogGuard {
        let assetutil = try XCTUnwrap(AppleToolDiscovery.locate("assetutil"), "assetutil must be discoverable via xcrun")
        return AssetCatalogGuard(assetutil: try LocalFileSystemTool(localPath: assetutil))
    }

    /// Canonicalises `original` and checks the result with the real assetutil.
    private func canonicalGuarded(_ original: [UInt8]) throws -> CanonicalAssetCatalog {
        let canonical = try AssetCatalogCanonicaliser.canonicalise(original)
        try catalogGuard().check(originalHash: try original.intern(), canonicalHash: try canonical.bytes.intern(), canonical: canonical)
        return canonical
    }

    // MARK: - The appearance table

    func test_twoCompilesOfTheWidgetsCatalogCanonicaliseToTheSameBytes() throws {
        let first  = try Self.widgetsCatalog(1)
        let second = try Self.widgetsCatalog(2)
        XCTAssertNotEqual(first.internedHash, second.internedHash, "the fixture is two compiles actool wrote differently")

        let firstCanonical  = try canonicalGuarded(first)
        let secondCanonical = try canonicalGuarded(second)

        XCTAssertEqual(firstCanonical.bytes.internedHash, secondCanonical.bytes.internedHash)
        XCTAssertTrue(firstCanonical.renamedRenditions.isEmpty, "a catalog without an .icon has no generated names")
    }

    /// The appearance identifiers are CoreUI's own, not an order: the canonical table keeps
    /// them as actool wrote them, in name order.
    func test_theAppearanceTableKeepsItsIdentifiersInNameOrder() throws {
        let canonical = try BOMStore(bytes: try AssetCatalogCanonicaliser.canonicalise(try Self.widgetsCatalog(2)).bytes)
        let appearances = try XCTUnwrap(canonical.variable(named: "APPEARANCEKEYS"))

        let table = try BOMTree.leafEntries(store: canonical, variable: appearances).map { entry in
            (String(decoding: try canonical.block(entry.key, referredToBy: "test"), as: UTF8.self),
             try canonical.block(entry.valueOrChild, referredToBy: "test").littleEndianUInt16(at: 0))
        }

        XCTAssertEqual(table.map(\.0), ["UIAppearanceAny", "UIAppearanceDark"])
        XCTAssertEqual(table.map(\.1), [0, 1])
    }

    /// A canonical file is its own canonical form.
    func test_canonicalisingTwiceChangesNothing() throws {
        let once  = try AssetCatalogCanonicaliser.canonicalise(try Self.widgetsCatalog(1)).bytes
        let twice = try AssetCatalogCanonicaliser.canonicalise(once).bytes

        XCTAssertEqual(once.internedHash, twice.internedHash)
    }

    // MARK: - An Icon Composer icon

    /// `Fixtures/AssetCatalogs/Icon.icon` compiled by the real actool, the node's arguments,
    /// in a sandbox of its own: the raw `Assets.car`.
    private func compileIcon() throws -> [UInt8] {
        let actool = try XCTUnwrap(AppleToolDiscovery.locate("actool"), "actool must be discoverable via xcrun")
        let icon   = Self.fixtures.appendingPathComponent("Icon.icon", isDirectory: true)
        let inputs = try ["icon.json", "Assets/dot.svg"].map { path in
            FileNameAndContent(filePath: "Icon.icon/\(path)",
                               hash: try DataObjectStore.shared.store(fileAt: icon.appendingPathComponent(path)))
        }
        let result = try LocalFileSystemTool(localPath: actool).execute(
            arguments: ["Icon.icon", "--compile", "out", "--platform", "iphonesimulator",
                        "--minimum-deployment-target", "18.0", "--target-device", "iphone",
                        "--app-icon", "Icon", "--output-partial-info-plist", "partial.plist",
                        "--output-format", "human-readable-text"],
            environment: [:],
            inputFiles: inputs,
            expectedOutputFileNames: ["partial.plist"],
            expectedOutputFolders: ["out"])
        XCTAssertEqual(result.exitCode, 0, result.printedOutput)
        let catalog = try XCTUnwrap(result.outputTrees["out"]?.first { $0.path == "Assets.car" })
        return try XCTUnwrap(catalog.hash).resolve()
    }

    /// The icon facet's key token and where its part is in the file, found by its bytes.
    private func iconFacetPart(in catalog: [UInt8]) throws -> (part: UInt16, offset: Int) {
        let store  = try BOMStore(bytes: catalog)
        let facets = try XCTUnwrap(store.variable(named: "FACETKEYS"))
        let entry  = try XCTUnwrap(try BOMTree.leafEntries(store: store, variable: facets).first { entry in
            try store.block(entry.key, referredToBy: "test") == Array("Icon".utf8)
        })
        let token = try store.block(entry.valueOrChild, referredToBy: "test")
        let pairs = (0..<Int(token.littleEndianUInt16(at: 4))).map { 6 + 4 * $0 }
        let partOffset = try XCTUnwrap(pairs.first { token.littleEndianUInt16(at: $0) == AssetCatalogCanonicaliser.partAttribute }) + 2
        let tokenStart = try XCTUnwrap(catalog.firstRange(of: token)).lowerBound
        return (token.littleEndianUInt16(at: partOffset), tokenStart + partOffset)
    }

    /// Every compile names the rendered icons afresh, and the icon's facet names the
    /// flattened images in some compiles and the stack in others. Both compiles, and each
    /// with its facet naming the other part — the file actool writes on another run — have
    /// one canonical form, with no generated name left in it.
    func test_anIconCompiledTwiceCanonicalisesToTheSameBytes() throws {
        let first  = try compileIcon()
        let second = try compileIcon()
        XCTAssertNotEqual(first.internedHash, second.internedHash, "actool names an icon's renditions afresh on every compile")

        var variants = [first, second]
        for compile in [first, second] {
            let facet = try iconFacetPart(in: compile)
            XCTAssertTrue(AssetCatalogCanonicaliser.iconParts.contains(facet.part), "part \(facet.part)")
            var otherPart = compile
            otherPart.setLittleEndianUInt16(facet.part == 220 ? 245 : 220, at: facet.offset)
            variants.append(otherPart)
        }

        let canonical = try variants.map { try canonicalGuarded($0) }

        for other in canonical.dropFirst() {
            XCTAssertEqual(other.bytes.internedHash, canonical[0].bytes.internedHash)
        }
        XCTAssertEqual(try iconFacetPart(in: canonical[0].bytes).part, AssetCatalogCanonicaliser.iconStackPart)
        XCTAssertEqual(canonical[0].renamedRenditions.count, 3, "the icon's Any, Dark and tinted renderings")
        for name in canonical[0].renamedRenditions.values {
            XCTAssertNil(GeneratedName.firstRange(in: Array(name.utf8)[...]), name)
            XCTAssertTrue(name.hasPrefix("Icon1024x1024_") && name.hasSuffix(".png"), name)
        }
    }

    // MARK: - The guard

    /// A canonical file with one byte of a rendition changed — a colour's component, deep in
    /// the `RENDITIONS` tree — reads differently through assetutil, and the guard names the
    /// rendition and what differed.
    func test_aCanonicalCatalogWithAByteFlippedInATreeFailsTheGuard() throws {
        let original  = try Self.widgetsCatalog(1)
        let canonical = try AssetCatalogCanonicaliser.canonicalise(original)
        let store     = try BOMStore(bytes: canonical.bytes)
        let entry     = try XCTUnwrap(try BOMTree.leafEntries(store: store, variable: XCTUnwrap(store.variable(named: "RENDITIONS"))).first)
        let value     = try store.block(entry.valueOrChild, referredToBy: "test")
        let offset    = try XCTUnwrap(canonical.bytes.firstRange(of: value)).upperBound - 1

        var corrupted = canonical.bytes
        corrupted[offset] ^= 0x01

        XCTAssertThrowsError(try catalogGuard().check(originalHash: try original.intern(),
                                                      canonicalHash: try corrupted.intern(),
                                                      canonical: canonical)) { error in
            guard case AssetCatalogGuardError.entriesDiffer(let differences) = error else {
                return XCTFail("expected the entries to differ, got \(error)")
            }
            XCTAssertTrue(differences.contains { $0.contains("SHA1Digest") }, "\(differences)")
        }
    }

    /// A canonical file assetutil cannot read at all is a failure too.
    func test_aCanonicalCatalogAssetutilCannotReadFailsTheGuard() throws {
        let original  = try Self.widgetsCatalog(1)
        let canonical = try AssetCatalogCanonicaliser.canonicalise(original)

        XCTAssertThrowsError(try catalogGuard().check(originalHash: try original.intern(),
                                                      canonicalHash: try Array(canonical.bytes.prefix(4096)).intern(),
                                                      canonical: canonical)) { error in
            guard case AssetCatalogGuardError.unreadable(let copy, _) = error else {
                return XCTFail("expected an unreadable catalog, got \(error)")
            }
            XCTAssertEqual(copy, .canonical)
        }
    }

    // MARK: - What cannot be canonicalised

    func test_aFileThatIsNotABOMStoreIsAnError() {
        XCTAssertThrowsError(try AssetCatalogCanonicaliser.canonicalise(Array("car".utf8))) { error in
            XCTAssertEqual("\(error)", "Assets.car cannot be read as a BOM store: it does not open with 'BOMStore'")
        }
    }

    /// A block nothing reaches holds something no rule here knows about, so it is an error
    /// rather than dropped.
    func test_aBlockNoVariableReachesIsAnError() throws {
        var store = try BOMStore(bytes: try Self.widgetsCatalog(1))
        store.blocks.append(Array("stray".utf8))

        XCTAssertThrowsError(try AssetCatalogCanonicaliser.canonicalise(store.serialised())) { error in
            XCTAssertTrue("\(error)".contains("reached from no variable"), "\(error)")
        }
    }

    func test_aGeneratedNameIsFoundWhereActoolPutsIt() {
        let name = "AppIcon1024x1024_UIAppearanceAny_72570FC2-24F1-4002-909B-FB89CE1E9414-80704-000019D119512FC9.png"
        let range = GeneratedName.firstRange(in: Array(name.utf8)[...])

        XCTAssertEqual(range, 33..<(name.utf8.count - 4))
        XCTAssertNil(GeneratedName.firstRange(in: Array("AppIcon1024x1024_UIAppearanceAny.png".utf8)[...]))
        XCTAssertNil(GeneratedName.firstRange(in: Array("72570FC2-24F1-4002-909B-FB89CE1E9414-80704-000019D1".utf8)[...]))
    }
}
