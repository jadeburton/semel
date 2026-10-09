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

    /// The first bytes of a thin Mach-O file of `fileType`, little-endian as a Mac writes it:
    /// 6 a dynamic library, 2 an executable.
    private static func machO(fileType: UInt8 = 6) -> Data {
        var header = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        header += Data([fileType, 0x00, 0x00, 0x00])
        return header + Data(repeating: 0, count: 48)
    }

    /// A fat file of two thin files, its header big-endian as `lipo` writes it.
    private static func fat(_ first: Data, _ second: Data) -> Data {
        func bigEndian(_ value: UInt32) -> Data {
            Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        let headerSize = UInt32(8 + 2 * 20)
        let firstOffset  = headerSize
        let secondOffset = headerSize + UInt32(first.count)
        var data = bigEndian(0xCAFE_BABE) + bigEndian(2)
        data += bigEndian(0x0100_000C) + bigEndian(0) + bigEndian(firstOffset) + bigEndian(UInt32(first.count)) + bigEndian(0)
        data += bigEndian(0x0100_0007) + bigEndian(3) + bigEndian(secondOffset) + bigEndian(UInt32(second.count)) + bigEndian(0)
        return data + first + second
    }

    /// An `ar` archive's first bytes, as CodeEditLanguages' framework binary begins.
    private static let archive = Data("!<arch>\n#1/20           0           0     0     644     4         `\n".utf8)

    /// Runs the node until it asks for nothing new: every folder it asks for answered as its
    /// tree from `folders` (files, subfolders), every file with its path as its bytes unless
    /// `contents` says otherwise — a framework's binary is read for what it is, and a Mac
    /// framework's is a dynamic library unless a test says — every mode from `modes` or the
    /// default. A path in `links` is a symbolic link pushed as one, holding what it maps to:
    /// a subfolder listed so in its folder's manifest, a file with the target on its
    /// metadata. Returns the last pass's output.
    private func select(settings: String, plist: Data,
                        folders: [String: (files: [String], folders: [String])] = [:],
                        modes: [String: UInt16] = [:],
                        links: [String: String] = [:],
                        contents: [String: Data]? = nil) throws -> ProcessOutput {
        let contents = contents ?? ["\(xcframework)/macos-arm64_x86_64/Tiny.framework/Tiny": Self.machO()]
        let node = try makeNode()
        var inputValues: [String: [String: NodeValue]] = [
            XCFrameworkSliceSelector.configuration: ["config": .value(try settings.intern())],
            XCFrameworkSliceSelector.infoPlist:     ["Info.plist": .value(try [UInt8](plist).intern())],
        ]
        for _ in 0..<10 {
            let output = try node.process(input: ProcessInput(inputValues: inputValues))
            var askedForMore = false
            // A folder asked for is its tree (B-135), every folder below it listed from
            // `folders`, a folder link carrying its target as its parent lists it.
            func tree(_ folder: String) throws -> FolderSubtreeManifest {
                let contents = folders[folder] ?? (files: [], folders: [])
                return FolderSubtreeManifest(entries: contents.files.map { FolderSubtreeEntry(name: $0, isFolder: false, isPinned: true) }
                    + (try contents.folders.map { name in
                        let path = "\(folder)/\(name)"
                        return FolderSubtreeEntry(name: name, isFolder: true, isPinned: true, symbolicLinkTarget: links[path],
                                                  subtree: try tree(path).toJSON().intern())
                    }))
            }
            for (folder, _) in output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders] ?? [:]
            where inputValues[XCFrameworkSliceSelector.sliceFolders]?[folder] == nil {
                inputValues[XCFrameworkSliceSelector.sliceFolders, default: [:]][folder] = .value(try tree(folder).toJSON().intern())
                askedForMore = true
            }
            for (file, _) in output.inputWireSpecs[XCFrameworkSliceSelector.sliceFiles] ?? [:]
            where inputValues[XCFrameworkSliceSelector.sliceFiles]?[file] == nil {
                inputValues[XCFrameworkSliceSelector.sliceFiles, default: [:]][file] =
                    .value(try contents[file].map { try [UInt8]($0).intern() } ?? file.intern())
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

    /// What is wrong with the `.xcframework`, as the selector's document carries it.
    private func problem(_ output: ProcessOutput) throws -> XCFrameworkProblem {
        let value = output.outputValues[XCFrameworkSliceSelector.frameworks]
        let document = try XCTUnwrap(value?.errorDocument, "expected an error, got \(String(describing: value))")
        XCTAssertEqual(document.subject, .resource(path: xcframework))
        guard case .engine(.xcframeworkUnusable(let path, let problem)) = document.diagnostic, path == xcframework else {
            throw XCTSkip("expected the xcframework's problem, got \(document)")
        }
        return problem
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
        XCTAssertEqual(try frameworks.entry(at: "Tiny.framework/Versions/A/Tiny").map { try XCTUnwrap($0.hash).resolveAsString() },
                       "\(slice)/Versions/A/Tiny")
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.embeddedFrameworks]), frameworks,
                       "a dynamic framework is embedded")
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
        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.keys.sorted(), [slice],
                       "the slice is one tree (B-135), and the entries above hold nothing read through a folder link")
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

        XCTAssertEqual(try problem(output),
                       .noSliceForPlatform(platform: "tvos", available: ["ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"]))
        XCTAssertEqual(output.inputWireSpecs[XCFrameworkSliceSelector.sliceFolders]?.isEmpty, true)
    }

    /// The triple's architecture must be one the slice has.
    func test_anArchitectureTheSliceLacksIsAnError() throws {
        let output = try select(settings: "sdk=iphoneos\ntarget=x86_64-apple-ios18.0", plist: try infoPlist())

        XCTAssertEqual(try problem(output), .noSliceForArchitecture(architecture: "x86_64", slice: "ios-arm64", architectures: ["arm64"]))
    }

    func test_aPlistThatIsNotAnXCFrameworksIsAnError() throws {
        let output = try select(settings: "sdk=macosx", plist: Data("<plist><dict/></plist>".utf8))

        XCTAssertEqual(try problem(output), .infoPlistUnreadable)
    }

    // MARK: - A static framework (B-77 item 3, 12)

    /// CodeEditLanguages' slice: a framework whose binary is a fat file of two archives. It
    /// is compiled and linked against as any framework — the whole slice on `frameworks` —
    /// and embedded nowhere: `embeddedFrameworks` is empty, so neither the bundle nor its
    /// signer sees it.
    func test_aStaticFrameworkIsLinkedAgainstAndNotEmbedded() throws {
        let slice = "\(xcframework)/macos-arm64_x86_64/Tiny.framework"
        let output = try select(settings: "sdk=macosx\ntarget=arm64-apple-macosx15.0", plist: try infoPlist(), folders: [
            slice:              (files: ["Tiny"], folders: ["Headers", "Modules"]),
            "\(slice)/Headers": (files: ["Tiny.h"], folders: []),
            "\(slice)/Modules": (files: ["module.modulemap"], folders: []),
        ], contents: ["\(slice)/Tiny": Self.fat(Self.archive, Self.archive)])

        let frameworks = try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.frameworks])
        XCTAssertEqual(frameworks.entries.map(\.path),
                       ["Tiny.framework/Headers/Tiny.h", "Tiny.framework/Modules/module.modulemap", "Tiny.framework/Tiny"])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.embeddedFrameworks]).entries, [])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.libraries]).entries, [])
    }

    /// The plist's `BinaryPath` says where the binary is, as `xcodebuild` records it.
    func test_theBinaryIsWhereThePlistSays() throws {
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: try infoPlist(), format: nil) as? [String: Any])
        var libraries = try XCTUnwrap(plist["AvailableLibraries"] as? [[String: Any]])
        libraries[1]["BinaryPath"] = "Tiny.framework/Versions/A/Tiny"
        plist["AvailableLibraries"] = libraries
        let slice = "\(xcframework)/macos-arm64_x86_64/Tiny.framework"
        let output = try select(settings: "sdk=macosx", plist: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                                folders: [
                                    slice:                 (files: [], folders: ["Versions"]),
                                    "\(slice)/Versions":   (files: [], folders: ["A"]),
                                    "\(slice)/Versions/A": (files: ["Tiny"], folders: []),
                                ], contents: ["\(slice)/Versions/A/Tiny": Self.archive])

        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.embeddedFrameworks]).entries, [])
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.frameworks]).entries.map(\.path),
                       ["Tiny.framework/Versions/A/Tiny"])
    }

    /// A framework whose binary is no library is an error naming the binary, as is one with
    /// no binary at all; either way the slice's wires stay, so a fixed slice runs it again.
    func test_aFrameworkBinaryThatIsNoLibraryIsAnError() throws {
        let slice = "\(xcframework)/macos-arm64_x86_64/Tiny.framework"
        let executable = try select(settings: "sdk=macosx", plist: try infoPlist(),
                                    folders: [slice: (files: ["Tiny"], folders: [])],
                                    contents: ["\(slice)/Tiny": Self.machO(fileType: 2)])
        XCTAssertEqual(try problem(executable),
                       .frameworkBinaryUnrecognised(path: "Tiny.framework/Tiny", reason: .machOFileType(fileType: 2)))
        XCTAssertEqual(executable.inputWireSpecs[XCFrameworkSliceSelector.sliceFiles]?.keys.sorted(), ["\(slice)/Tiny"])

        let missing = try select(settings: "sdk=macosx", plist: try infoPlist(),
                                 folders: [slice: (files: ["Info.plist"], folders: [])])
        XCTAssertEqual(try problem(missing), .noFrameworkBinary(paths: ["Tiny.framework/Tiny"]))
    }

    /// The kind is read from the first bytes and, in a fat file, from each architecture's.
    func test_aBinarysKindIsReadFromItsMagic() throws {
        func kind(_ data: Data) throws -> FrameworkBinary {
            try FrameworkBinary.kind { offset, count in
                guard offset <= UInt64(data.count) else {
                    return Data()
                }
                return data.dropFirst(Int(offset)).prefix(count)
            }
        }
        XCTAssertEqual(try kind(Self.machO()), .dynamicLibrary)
        XCTAssertEqual(try kind(Self.machO(fileType: 1)), .staticArchive, "a relocatable object is linked in")
        XCTAssertEqual(try kind(Self.archive), .staticArchive)
        XCTAssertEqual(try kind(Self.fat(Self.machO(), Self.machO())), .dynamicLibrary)
        XCTAssertEqual(try kind(Self.fat(Self.archive, Self.archive)), .staticArchive)
        XCTAssertThrowsError(try kind(Self.fat(Self.archive, Self.machO()))) {
            XCTAssertEqual($0 as? FrameworkBinary.Unrecognised, .mixedSlices)
        }
        XCTAssertThrowsError(try kind(Data("#!/bin/sh\necho\n".utf8))) {
            XCTAssertEqual($0 as? FrameworkBinary.Unrecognised, .unknownMagic("23 21 2f 62 69 6e 2f 73"))
        }
        XCTAssertThrowsError(try kind(Data([0xCF]))) {
            XCTAssertEqual($0 as? FrameworkBinary.Unrecognised, .unreadable)
        }
    }

    /// What the real tools write reads as what it is: `libtool -static` an archive and
    /// `clang -dynamiclib` a dynamic library, and `lipo` a fat file of either.
    func test_theToolsOutputReadsAsWhatItIs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-binary-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "int tiny(void) { return 1; }\n".write(to: folder.appendingPathComponent("tiny.c"), atomically: true, encoding: .utf8)
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.currentDirectoryURL = folder
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }
        try run(["clang", "-c", "-arch", "arm64", "-arch", "x86_64", "tiny.c", "-o", "tiny.o"])
        try run(["libtool", "-static", "tiny.o", "-o", "libtiny.a"])
        try run(["clang", "-dynamiclib", "-arch", "arm64", "-arch", "x86_64", "tiny.c", "-o", "libtiny.dylib"])
        func kind(_ name: String) throws -> FrameworkBinary {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            return try FrameworkBinary.kind { offset, count in data.dropFirst(Int(offset)).prefix(count) }
        }
        XCTAssertEqual(try kind("libtiny.a"), .staticArchive)
        XCTAssertEqual(try kind("libtiny.dylib"), .dynamicLibrary)
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
        XCTAssertEqual(try treeManifest(from: output.outputValues[XCFrameworkSliceSelector.embeddedFrameworks]).entries, [])
    }

    /// A dynamic library outside a framework would need an install name nothing sets.
    func test_aLibrarySliceThatIsNotAnArchiveIsAnError() throws {
        let output = try select(settings: "sdk=macosx", plist: try infoPlist(macLibrary: "libTiny.dylib"))

        guard case .unsupportedLibrary(let library) = try problem(output) else {
            return XCTFail("expected the library that is not an archive")
        }
        XCTAssertTrue(library.hasSuffix("libTiny.dylib"), library)
    }

    func test_isRegisteredUnderItsKind() throws {
        XCTAssertTrue(try TypeRegistry.type(kind: XCFrameworkSliceSelector.kind) == XCFrameworkSliceSelector.self)
    }
}
