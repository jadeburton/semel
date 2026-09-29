//
//  XCFrameworkSliceSelectorTests.swift
//  SemelAppleTests
//
//  Which slice of an `.xcframework` a build takes, and the trees the slice becomes (B-77):
//  the node read pass by pass, each pass given what the one before asked for, over a
//  hand-written `Info.plist` shaped as `xcodebuild -create-xcframework` writes one.
//

@testable import SemelApple
import Foundation
import SemelNodeKit
import SemelDatabaseModels
import XCTest

final class XCFrameworkSliceSelectorTests: SemelAppleTestCase {

    private let xcframework = "input:/pkg/semel-artifacts/Tiny/Tiny.xcframework"

    /// Three slices, as a framework built for the Mac, the iPhone and its simulator has.
    private func infoPlist(macLibrary: String = "Tiny.framework", macHeaders: String? = nil) throws -> Data {
        var mac: [String: Any] = ["LibraryIdentifier": "macos-arm64_x86_64", "LibraryPath": macLibrary,
                                  "SupportedArchitectures": ["arm64", "x86_64"], "SupportedPlatform": "macos"]
        if let macHeaders {
            mac["HeadersPath"] = macHeaders
        }
        let plist: [String: Any] = [
            "AvailableLibraries": [
                ["LibraryIdentifier": "ios-arm64", "LibraryPath": "Tiny.framework",
                 "SupportedArchitectures": ["arm64"], "SupportedPlatform": "ios"],
                mac,
                ["LibraryIdentifier": "ios-arm64_x86_64-simulator", "LibraryPath": "Tiny.framework",
                 "SupportedArchitectures": ["arm64", "x86_64"], "SupportedPlatform": "ios", "SupportedPlatformVariant": "simulator"],
            ],
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func makeNode() throws -> XCFrameworkSliceSelector {
        try XCFrameworkSliceSelector(thisNode: NodeRecord(id: 1, kind: XCFrameworkSliceSelector.kind,
                                                          properties: [XCFrameworkSliceSelector.pathProperty: xcframework]))
    }

    /// Runs the node until it asks for nothing new: every folder it asks for answered from
    /// `folders` (files, subfolders), every file with its path as its bytes, every mode from
    /// `modes` or the default. A path in `links` is a symbolic link pushed as one, holding
    /// what it maps to: a subfolder listed so in its folder's manifest, a file with the
    /// target on its metadata. Returns the last pass's output.
    private func select(settings: String, plist: Data,
                        folders: [String: (files: [String], folders: [String])] = [:],
                        modes: [String: UInt16] = [:],
                        links: [String: String] = [:]) throws -> ProcessOutput {
        let node = try makeNode()
        var inputValues: [String: [String: NodeValue]] = [
            XCFrameworkSliceSelector.configuration: ["config": .value(try settings.intern())],
            XCFrameworkSliceSelector.infoPlist:     ["Info.plist": .value(try [UInt8](plist).intern())],
        ]
        for _ in 0..<10 {
            let output = try node.process(input: ProcessInput(inputValues: inputValues))
            var askedForMore = false
            for (folder, _) in output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders] ?? [:]
            where inputValues[XCFrameworkSliceSelector.sliceFolders]?[folder] == nil {
                let contents = folders[folder] ?? (files: [], folders: [])
                let folderLinks = Dictionary(contents.folders.compactMap { name in links["\(folder)/\(name)"].map { (name, $0) } }) { first, _ in first }
                inputValues[XCFrameworkSliceSelector.sliceFolders, default: [:]][folder] =
                    try manifestValue(folder, files: contents.files, folders: contents.folders, folderLinks: folderLinks)
                askedForMore = true
            }
            for (file, _) in output.inputWireSpecs[XCFrameworkSliceSelector.sliceFiles] ?? [:]
            where inputValues[XCFrameworkSliceSelector.sliceFiles]?[file] == nil {
                inputValues[XCFrameworkSliceSelector.sliceFiles, default: [:]][file] = .value(try file.intern())
                inputValues[XCFrameworkSliceSelector.sliceFileMetadata, default: [:]][file] =
                    .value(try FileMetadata(mode: modes[file] ?? FileMetadata.defaultMode, symbolicLinkTarget: links[file]).jsonString().intern())
                askedForMore = true
            }
            guard askedForMore else {
                return output
            }
        }
        XCTFail("the selector kept asking for more")
        return try node.process(input: ProcessInput(inputValues: inputValues))
    }

    private func errorMessage(_ output: ProcessOutput) throws -> String {
        guard case .noValue(.error(let hash)) = output.outputValues[XCFrameworkSliceSelector.frameworks] else {
            XCTFail("expected an error, got \(String(describing: output.outputValues[XCFrameworkSliceSelector.frameworks]))")
            return ""
        }
        return try hash.resolveAsString()
    }

    // MARK: - Which slice

    /// The Mac's slice for a Mac build, walked whole and published under the framework's
    /// name, every file keeping its mode; the other two trees empty.
    func test_aMacBuildTakesTheMacSliceWholeUnderTheFrameworksName() throws {
        let slice = "\(xcframework)/macos-arm64_x86_64/Tiny.framework"
        let output = try select(settings: "sdk=macosx\ntarget=arm64-apple-macosx15.0", plist: try infoPlist(), folders: [
            slice:                          (files: ["Tiny"], folders: ["Versions", "Resources"]),
            "\(slice)/Versions":            (files: [], folders: ["A"]),
            "\(slice)/Versions/A":          (files: ["Tiny"], folders: []),
            "\(slice)/Resources":           (files: ["Info.plist"], folders: []),
        ], modes: ["\(slice)/Tiny": 0o755, "\(slice)/Versions/A/Tiny": 0o755])

        let frameworks = try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.frameworks])
        XCTAssertEqual(frameworks.entries.map(\.path),
                       ["Tiny.framework/Resources/Info.plist", "Tiny.framework/Tiny", "Tiny.framework/Versions/A/Tiny"])
        XCTAssertEqual(frameworks.entry(at: "Tiny.framework/Versions/A/Tiny")?.mode, 0o755)
        XCTAssertEqual(frameworks.entry(at: "Tiny.framework/Resources/Info.plist")?.mode, 0o644)
        XCTAssertEqual(try frameworks.entry(at: "Tiny.framework/Tiny").map { try XCTUnwrap($0.hash).resolveAsString() }, "\(slice)/Tiny")
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.libraries]).entries, [])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.headers]).entries, [])
        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.keys.allSatisfy { $0.hasPrefix(slice) }, true,
                       "no other slice is read")
    }

    /// A versioned framework pushed with its links (B-77): `Versions/Current` and the links
    /// at the top are links in the tree, and nothing is read through one — the version they
    /// name is walked where it is, once.
    func test_aVersionedFrameworksLinksAreLinksInItsTree() throws {
        let slice = "\(xcframework)/macos-arm64_x86_64/Tiny.framework"
        let output = try select(settings: "sdk=macosx\ntarget=arm64-apple-macosx15.0", plist: try infoPlist(), folders: [
            slice:                          (files: ["Tiny"], folders: ["Versions", "Resources"]),
            "\(slice)/Versions":            (files: [], folders: ["A", "Current"]),
            "\(slice)/Versions/A":          (files: ["Tiny"], folders: ["Resources"]),
            "\(slice)/Versions/A/Resources": (files: ["Info.plist"], folders: []),
        ], modes: ["\(slice)/Tiny": 0o755, "\(slice)/Versions/A/Tiny": 0o755], links: [
            "\(slice)/Versions/Current": "A",
            "\(slice)/Tiny":             "Versions/Current/Tiny",
            "\(slice)/Resources":        "Versions/Current/Resources",
        ])

        let frameworks = try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.frameworks])
        XCTAssertEqual(frameworks.entries, [
            TreeManifestEntry(path: "Tiny.framework/Resources", symbolicLinkTarget: "Versions/Current/Resources"),
            TreeManifestEntry(path: "Tiny.framework/Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
            TreeManifestEntry(path: "Tiny.framework/Versions/A/Resources/Info.plist",
                              hash: try "\(slice)/Versions/A/Resources/Info.plist".intern(), mode: 0o644),
            TreeManifestEntry(path: "Tiny.framework/Versions/A/Tiny", hash: try "\(slice)/Versions/A/Tiny".intern(), mode: 0o755),
            TreeManifestEntry(path: "Tiny.framework/Versions/Current", symbolicLinkTarget: "A"),
        ])
        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.keys.sorted(),
                       [slice, "\(slice)/Versions", "\(slice)/Versions/A", "\(slice)/Versions/A/Resources"],
                       "no folder link is walked")
    }

    /// The simulator's slice is the `ios` one with the `simulator` variant, not the device's.
    func test_aSimulatorBuildTakesTheSimulatorSlice() throws {
        let output = try select(settings: "sdk=iphonesimulator\ntarget=arm64-apple-ios18.0-simulator", plist: try infoPlist())

        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.keys.sorted(),
                       ["\(xcframework)/ios-arm64_x86_64-simulator/Tiny.framework"])
    }

    func test_theSDKSaysThePlatform() {
        XCTAssertEqual(XCFrameworkPlatform(sdk: "macosx", target: nil), XCFrameworkPlatform(platform: "macos", variant: nil))
        XCTAssertEqual(XCFrameworkPlatform(sdk: "iphoneos", target: "arm64-apple-ios18.0"), XCFrameworkPlatform(platform: "ios", variant: nil))
        XCTAssertEqual(XCFrameworkPlatform(sdk: "macosx", target: "arm64-apple-ios17.0-macabi"),
                       XCFrameworkPlatform(platform: "ios", variant: "maccatalyst"))
        XCTAssertNil(XCFrameworkPlatform(sdk: "linux", target: nil))
    }

    /// A platform the framework was not built for is an error naming the slices it has.
    func test_noSliceForThePlatformIsAnErrorNamingTheSlices() throws {
        let output = try select(settings: "sdk=appletvos", plist: try infoPlist())

        XCTAssertEqual(try errorMessage(output),
                       "XCFrameworkSliceSelector: \(xcframework): it has no slice for tvos; its slices are "
                     + "ios-arm64, ios-arm64_x86_64-simulator, macos-arm64_x86_64")
        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.isEmpty, true)
    }

    /// The triple's architecture must be one the slice has.
    func test_anArchitectureTheSliceLacksIsAnError() throws {
        let output = try select(settings: "sdk=iphoneos\ntarget=x86_64-apple-ios18.0", plist: try infoPlist())

        XCTAssertEqual(try errorMessage(output),
                       "XCFrameworkSliceSelector: \(xcframework): its slice ios-arm64 has no x86_64, only arm64")
    }

    func test_aPlistThatIsNotAnXCFrameworksIsAnError() throws {
        let output = try select(settings: "sdk=macosx", plist: Data("<plist><dict/></plist>".utf8))

        XCTAssertTrue(try errorMessage(output).contains("its Info.plist is not an xcframework's"))
    }

    // MARK: - A static library slice

    /// A static library slice is its archive on `libraries` and its headers on `headers`,
    /// relative to their folder; nothing is on `frameworks`, so nothing is embedded.
    func test_aStaticLibrarySliceIsItsArchiveAndItsHeaders() throws {
        let slice = "\(xcframework)/macos-arm64_x86_64"
        let output = try select(settings: "sdk=macosx", plist: try infoPlist(macLibrary: "libTiny.a", macHeaders: "Headers"), folders: [
            "\(slice)/Headers": (files: ["Tiny.h", "module.modulemap"], folders: []),
        ])

        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.libraries]).entries.map(\.path), ["libTiny.a"])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.headers]).entries.map(\.path),
                       ["Tiny.h", "module.modulemap"])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.frameworks]).entries, [])
    }

    /// A dynamic library outside a framework would need an install name nothing sets.
    func test_aLibrarySliceThatIsNotAnArchiveIsAnError() throws {
        let output = try select(settings: "sdk=macosx", plist: try infoPlist(macLibrary: "libTiny.dylib"))

        XCTAssertTrue(try errorMessage(output).contains("libTiny.dylib is neither a framework nor a static archive"))
    }

    func test_isRegisteredUnderItsKind() throws {
        XCTAssertTrue(try TypeRegistry.type(kind: XCFrameworkSliceSelector.kind) == XCFrameworkSliceSelector.self)
    }
}
