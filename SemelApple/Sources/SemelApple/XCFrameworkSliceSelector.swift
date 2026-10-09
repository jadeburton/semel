//
//  XCFrameworkSliceSelector.swift
//  SemelApple
//
//  An `.xcframework` is one library built several times, a slice per platform, with an
//  `Info.plist` saying which folder holds which. A package's binary target is one (B-77,
//  Sparkle): which slice a build takes depends on the platform it builds for, which the
//  package converter does not know and should not — it writes one formula for a package
//  whatever the platform. So the choice is a node: it reads the plist and the platform the
//  settings name, walks the slice it chose and hands it on as trees, and the converter only
//  names it.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Platform

/// The platform an `.xcframework` slice is for, as its `Info.plist` names it:
/// `SupportedPlatform` (`macos`, `ios`) and `SupportedPlatformVariant` (`simulator`,
/// `maccatalyst`, or none for the device).
struct XCFrameworkPlatform: Equatable, CustomStringConvertible {
    let platform: String
    let variant: String?

    /// The platform a build is for, from the SDK it builds against and the `-target` triple,
    /// when there is one. nil for an SDK no `.xcframework` names a slice for.
    ///
    /// Mac Catalyst builds against `macosx` with a `-macabi` triple, and a Catalyst slice is
    /// an `ios` one with the `maccatalyst` variant, so the triple decides there.
    init?(sdk: String, target: String?) {
        if let target, target.hasSuffix("-macabi") {
            self.init(platform: "ios", variant: "maccatalyst")
            return
        }
        switch sdk {
        case "macosx":           self.init(platform: "macos",    variant: nil)
        case "iphoneos":         self.init(platform: "ios",      variant: nil)
        case "iphonesimulator":  self.init(platform: "ios",      variant: "simulator")
        case "appletvos":        self.init(platform: "tvos",     variant: nil)
        case "appletvsimulator": self.init(platform: "tvos",     variant: "simulator")
        case "watchos":          self.init(platform: "watchos",  variant: nil)
        case "watchsimulator":   self.init(platform: "watchos",  variant: "simulator")
        case "xros":             self.init(platform: "xros",     variant: nil)
        case "xrsimulator":      self.init(platform: "xros",     variant: "simulator")
        default:                 return nil
        }
    }

    init(platform: String, variant: String?) {
        self.platform = platform
        self.variant  = variant
    }

    /// `ios-simulator`, `macos`: how `xcodebuild -create-xcframework` names a slice's
    /// folder, and how an error names the platform.
    var description: String {
        variant.map { "\(platform)-\($0)" } ?? platform
    }
}

// MARK: - The plist

/// One entry of an `.xcframework`'s `AvailableLibraries`.
struct XCFrameworkSlice: Equatable {
    /// The slice's folder in the `.xcframework`: `macos-arm64_x86_64`.
    let identifier: String
    /// What is in that folder: `Sparkle.framework`, or `libTiny.a` for a static library.
    let libraryPath: String
    let platform: XCFrameworkPlatform
    let architectures: [String]
    /// A static library's headers, relative to the slice's folder; nil for a framework,
    /// which carries its own.
    let headersPath: String?
    /// The binary, relative to the slice's folder, as `xcodebuild -create-xcframework`
    /// records it: `Sparkle.framework/Versions/B/Sparkle`. Nil in a plist that does not say.
    let binaryPath: String?

    /// A framework is a folder with its binary, its headers and its module map inside; a
    /// library slice is the one file, with its headers beside it.
    var isFramework: Bool { libraryPath.hasSuffix(".framework") }

    /// Where a framework slice's binary may be, relative to the slice's folder, in the order
    /// to look: the plist's `BinaryPath`, then the framework's name inside it, which every
    /// layout has — the binary itself in a shallow framework, a link to it in a versioned
    /// one, and the one place left when `BinaryPath` names it through `Versions/Current`,
    /// a folder link the walk does not read through.
    var frameworkBinaryPaths: [String] {
        let byName = "\(libraryPath)/\((libraryPath as NSString).deletingPathExtension)"
        guard let binaryPath, binaryPath != byName else {
            return [byName]
        }
        return [binaryPath, byName]
    }

    /// Every slice the plist lists, in its order.
    static func slices(inInfoPlist data: Data) throws -> [XCFrameworkSlice] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let libraries = plist["AvailableLibraries"] as? [[String: Any]] else {
            throw XCFrameworkSliceError.unreadableInfoPlist
        }
        return try libraries.map { library in
            guard let identifier = library["LibraryIdentifier"] as? String,
                  let libraryPath = library["LibraryPath"] as? String,
                  let platform = library["SupportedPlatform"] as? String else {
                throw XCFrameworkSliceError.unreadableInfoPlist
            }
            return XCFrameworkSlice(identifier:    identifier,
                                    libraryPath:   libraryPath,
                                    platform:      XCFrameworkPlatform(platform: platform,
                                                                       variant: library["SupportedPlatformVariant"] as? String),
                                    architectures: library["SupportedArchitectures"] as? [String] ?? [],
                                    headersPath:   library["HeadersPath"] as? String,
                                    binaryPath:    library["BinaryPath"] as? String)
        }
    }

    /// The slice for `platform` — one at most, since `xcodebuild -create-xcframework`
    /// refuses two for one platform — when it has `architecture`, or whatever it has when
    /// the build names none.
    static func select(from slices: [XCFrameworkSlice], platform: XCFrameworkPlatform,
                       architecture: String?) throws -> XCFrameworkSlice {
        guard let slice = slices.first(where: { $0.platform == platform }) else {
            throw XCFrameworkSliceError.noSliceForPlatform(platform.description,
                                                           available: slices.map(\.identifier).sorted())
        }
        if let architecture, !slice.architectures.isEmpty, !slice.architectures.contains(architecture) {
            throw XCFrameworkSliceError.noSliceForArchitecture(architecture, slice: slice.identifier,
                                                               architectures: slice.architectures)
        }
        return slice
    }
}

/// Why no slice of an `.xcframework` is what a build can take, by case.
enum XCFrameworkSliceError: Error, Equatable, CustomStringConvertible {
    case unreadableInfoPlist
    case noPlatform(sdk: String)
    case noSliceForPlatform(String, available: [String])
    case noSliceForArchitecture(String, slice: String, architectures: [String])
    /// A library slice that is not a static archive: a dynamic library outside a framework
    /// would have to be embedded and found by an install name nothing here sets.
    case unsupportedLibrary(String)
    /// A framework slice with no file where its binary should be.
    case noFrameworkBinary(String)
    /// A framework slice whose binary is neither a dynamic library nor an archive.
    case unrecognisedFrameworkBinary(String, FrameworkBinary.Unrecognised)

    var description: String {
        switch self {
        case .unreadableInfoPlist:
            return "its Info.plist is not an xcframework's: no AvailableLibraries with a LibraryIdentifier, "
                 + "LibraryPath and SupportedPlatform each"
        case .noPlatform(let sdk):
            return "no xcframework slice is for the SDK \(sdk)"
        case .noSliceForPlatform(let platform, let available):
            return "it has no slice for \(platform); its slices are \(available.joined(separator: ", "))"
        case .noSliceForArchitecture(let architecture, let slice, let architectures):
            return "its slice \(slice) has no \(architecture), only \(architectures.joined(separator: ", "))"
        case .unsupportedLibrary(let path):
            return "its slice's library \(path) is neither a framework nor a static archive, which is all that is linked here"
        case .noFrameworkBinary(let path):
            return "its slice's framework has no binary at \(path)"
        case .unrecognisedFrameworkBinary(let path, let reason):
            return "its slice's framework binary \(path): \(reason)"
        }
    }
}

/// What a chosen slice is, which decides the trees it fills (B-77 item 3, 12).
enum XCFrameworkLibraryKind: Equatable {
    /// A framework whose binary is a dynamic library: compiled and linked against, and
    /// embedded in the bundle, where the executable's runpath finds it.
    case dynamicFramework
    /// A framework whose binary is an archive: compiled and linked against — `-F` finds its
    /// headers and module map, `-framework` links the archive in — and embedded nowhere,
    /// as Xcode embeds no static framework.
    case staticFramework
    /// A static library and its headers: linked as an archive, and embedded nowhere.
    case staticLibrary

    init(framework binary: FrameworkBinary) {
        switch binary {
        case .dynamicLibrary: self = .dynamicFramework
        case .staticArchive:  self = .staticFramework
        }
    }
}

// MARK: - Configuration

/// The two settings a slice is chosen by: the SDK and the `-target` triple. Read from the
/// Swift linker's settings, the ones the product the slice is linked into is linked by,
/// so the choice cannot disagree with the link — and no namespace of its own, which
/// `prepare` would have to write and nothing else would read.
struct XCFrameworkSliceSelectorConfiguration {
    let sdk: String
    let target: String?

    init(properties: [String: String]) {
        // The linker's own default when its settings name no SDK.
        sdk    = properties["sdk"] ?? "macosx"
        target = properties["target"]
    }

    /// `arm64` from `arm64-apple-macosx15.0`; nil when no triple is named.
    var architecture: String? {
        target.flatMap { $0.split(separator: "-").first.map(String.init) }
    }
}

// MARK: - Node

/// Picks the slice of one `.xcframework` for the platform being built and publishes it as
/// trees: a framework slice on `frameworks`, under its own name (`Sparkle.framework/…`),
/// which is what a compiler's `-F` and a linker's `-framework` find; the same tree on
/// `embeddedFrameworks` when the framework's binary is a dynamic library, which is what a
/// bundle embeds — a static framework's archive is linked into the executable and loaded
/// from nowhere, so it is not (`XCFrameworkLibraryKind`, read from the binary's first bytes);
/// a static library slice's archive on `libraries` and its headers on `headers`, which a
/// link and an import take instead, and nothing embeds. The ports a slice does not fill
/// carry the empty tree, so a formula wires all four without knowing which it is.
///
/// The slice is read from its folder's subtree manifest (B-135), and each file keeps the
/// mode it was pushed with: a framework holds executables (Sparkle's `Autoupdate`, its
/// `Updater.app`) that must stay ones in the bundle.
public struct XCFrameworkSliceSelector: Node {
    public static let kind: UInt = 40

    /// 2: a framework's symbolic links are links in its tree, where they were copies (B-77).
    /// 3: the slice's folder is asked for as a tree, where it was walked (B-135).
    /// 4: a framework's binary is read for its kind, and only a dynamic one is published on
    /// the new `embeddedFrameworks` (B-77 item 3, 12).
    /// 5: several wires on a one-wire port are an error naming them, where one was taken
    /// (B-141).
    public static let implementationVersion = 5

    // MARK: Ports

    /// Settings naming `sdk` and `target`; the Swift linker's, as the converter wires it.
    static let configuration = "configuration"
    /// The `.xcframework`'s `Info.plist`, one wire.
    static let infoPlist = "infoPlist"
    /// The subtree manifest of each folder of the chosen slice that is read whole — the
    /// framework, or a library's headers — keyed by its path.
    static let sliceFolders = "sliceFolders"
    /// Every file of the chosen slice, by path, and each one's mode beside it.
    static let sliceFiles = "sliceFiles"
    static let sliceFileMetadata = "sliceFileMetadata"

    static let frameworks = "frameworks"
    /// The frameworks a bundle embeds: `frameworks` when the slice is a dynamic framework,
    /// and empty otherwise.
    static let embeddedFrameworks = "embeddedFrameworks"
    static let libraries = "libraries"
    static let headers = "headers"

    static let outputPorts = [frameworks, embeddedFrameworks, libraries, headers]

    /// The `.xcframework` folder in the input file system: what the slice folders the
    /// plist names are relative to.
    static let pathProperty = "path"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(infoPlist),
            .dynamic(sliceFolders),
            .dynamic(sliceFiles),
            .dynamic(sliceFileMetadata),
        ],
        outputPorts: outputPorts
    )

    // MARK: Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        guard let xcframework = thisNode.properties[Self.pathProperty] else {
            throw NodeError.other(message: "XCFrameworkSliceSelector needs path: <the .xcframework folder>")
        }
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = XCFrameworkSliceSelectorConfiguration(properties: [String: String](plainText: configurationText))

        let slice: XCFrameworkSlice
        do {
            let plistValue = try input.onlyWire(onRequiredPort: Self.infoPlist).value
            guard let bytes = try DataObjectStore.shared.read(hash: try plistValue.expectValue()) else {
                throw XCFrameworkSliceError.unreadableInfoPlist
            }
            guard let platform = XCFrameworkPlatform(sdk: configuration.sdk, target: configuration.target) else {
                throw XCFrameworkSliceError.noPlatform(sdk: configuration.sdk)
            }
            slice = try XCFrameworkSlice.select(from: try XCFrameworkSlice.slices(inInfoPlist: Data(bytes)),
                                                platform: platform, architecture: configuration.architecture)
        } catch let error as XCFrameworkSliceError {
            return try failed("\(xcframework): \(error)")
        }

        let sliceFolder = Path(xcframework) / slice.identifier
        // A framework is walked whole; a library slice is its archive and, when it has
        // them, its headers' folder.
        var roots: [String] = []
        var singleFiles: [String] = []
        if slice.isFramework {
            roots.append((sliceFolder / slice.libraryPath).string)
        } else {
            guard slice.libraryPath.hasSuffix(".a") else {
                return try failed("\(xcframework): \(XCFrameworkSliceError.unsupportedLibrary(slice.libraryPath))")
            }
            singleFiles.append((sliceFolder / slice.libraryPath).string)
            if let headersPath = slice.headersPath {
                roots.append((sliceFolder / headersPath).string)
            }
        }

        // ── the slice's folders, as trees (B-135) ─────────────────────────────
        let trees = FolderTreeWalk.trees(in: input, port: Self.sliceFolders)
        var folderSpecs: [String: GraphSpecNode] = [:]
        var reached: [String: FolderManifest] = [:]
        for root in roots {
            folderSpecs[root] = .folderTree(at: root)
            guard let tree = trees[root] else {
                continue
            }
            reached.merge(try tree.folderManifests(at: root, intoSymbolicLinks: false)) { existing, _ in existing }
        }
        let walkedManifests = reached.keys.sorted().compactMap { reached[$0] }
        var fileSpecs = FolderTreeWalk.fileSpecs(of: walkedManifests)
        for file in singleFiles {
            fileSpecs[file] = .staticFile(at: file)
        }
        let specs = [Self.sliceFolders:      folderSpecs,
                     Self.sliceFiles:        fileSpecs,
                     Self.sliceFileMetadata: fileSpecs.mapValues { $0.port(FileMetadata.portName) }]

        let files    = input.inputValues[Self.sliceFiles] ?? [:]
        let metadata = input.inputValues[Self.sliceFileMetadata] ?? [:]
        guard Set(folderSpecs.keys).isSubset(of: Set(trees.keys)),
              Set(fileSpecs.keys).isSubset(of: Set(files.keys)),
              Set(fileSpecs.keys).isSubset(of: Set(metadata.keys)) else {
            let walking = NodeValue.noValue(reason: .pending)
            return .init(outputValues: Dictionary(uniqueKeysWithValues: Self.outputPorts.map { ($0, walking) }),
                         inputWireSpecs: specs)
        }

        // What the slice is: a library by its plist, a framework by its binary's first
        // bytes, read where the store holds them rather than whole.
        let kind: XCFrameworkLibraryKind
        if slice.isFramework {
            let candidates = slice.frameworkBinaryPaths
            guard let binaryPath = candidates.first(where: { files[(sliceFolder / $0).string] != nil }),
                  let binary = files[(sliceFolder / binaryPath).string] else {
                return try failed("\(xcframework): \(XCFrameworkSliceError.noFrameworkBinary(candidates.joined(separator: " or ")))",
                                  inputWireSpecs: specs)
            }
            let hash = try binary.expectValue()
            do {
                kind = XCFrameworkLibraryKind(framework: try FrameworkBinary.kind { offset, count in
                    DataObjectStore.shared.bytes(ofHash: hash, at: offset, count: count)
                })
            } catch let unrecognised as FrameworkBinary.Unrecognised {
                let error = XCFrameworkSliceError.unrecognisedFrameworkBinary(binaryPath, unrecognised)
                return try failed("\(xcframework): \(error)", inputWireSpecs: specs)
            }
        } else {
            kind = .staticLibrary
        }

        // Each file under where it goes: a framework under its own name, a library under
        // its file name, headers relative to their folder. A file pushed as a symbolic link
        // is the link it is — a framework's `Versions/Current` and the links at its top —
        // so the framework is the one the vendor built (B-77).
        let walkedFolderLinks = FolderTreeWalk.symbolicLinkFolders(of: walkedManifests)
        func tree(under root: String, placedUnder prefix: Path) throws -> TreeManifest {
            let placed = try fileSpecs.keys.sorted().compactMap { path -> TreeManifest.PlacedFile? in
                guard let relative = Path(path).relative(to: Path(root)), let value = files[path] else {
                    return nil
                }
                return .init(path: (prefix / relative).string, hash: try value.expectValue(),
                             metadata: FileMetadata.metadata(of: metadata[path]))
            }
            var folderLinks: [String: String] = [:]
            for (path, target) in walkedFolderLinks.sorted(by: { $0.key < $1.key }) {
                guard let relative = Path(path).relative(to: Path(root)) else {
                    continue
                }
                folderLinks[(prefix / relative).string] = target
            }
            return TreeManifest(placing: placed, folderLinks: folderLinks)
        }
        var frameworkTree = TreeManifest(entries: [])
        var libraryTree   = TreeManifest(entries: [])
        var headerTree    = TreeManifest(entries: [])
        if slice.isFramework {
            frameworkTree = try tree(under: (sliceFolder / slice.libraryPath).string, placedUnder: Path(slice.libraryPath))
        } else {
            var libraryFiles: [TreeManifest.PlacedFile] = []
            for file in singleFiles {
                guard let value = files[file], let name = Path(file).lastComponent else {
                    continue
                }
                libraryFiles.append(.init(path: name, hash: try value.expectValue(),
                                          metadata: FileMetadata.metadata(of: metadata[file])))
            }
            libraryTree = TreeManifest(placing: libraryFiles)
            if let headersPath = slice.headersPath {
                headerTree = try tree(under: (sliceFolder / headersPath).string, placedUnder: .empty)
            }
        }
        let frameworksValue = NodeValue.value(try frameworkTree.toJSON().intern())
        let embedded = kind == .dynamicFramework ? frameworksValue : .value(try TreeManifest(entries: []).toJSON().intern())
        return .init(outputValues: [Self.frameworks:         frameworksValue,
                                    Self.embeddedFrameworks: embedded,
                                    Self.libraries:          .value(try libraryTree.toJSON().intern()),
                                    Self.headers:            .value(try headerTree.toJSON().intern())],
                     inputWireSpecs: specs)
    }

    /// An error on every port. With no walk, when nothing was chosen and so nothing is to be
    /// read; with the walk's specs, when what was read is what failed, so that its wires
    /// stay and a change to the slice runs the node again.
    private func failed(_ message: String,
                        inputWireSpecs: [String: [String: GraphSpecNode]] = [Self.sliceFolders: [:], Self.sliceFiles: [:],
                                                                             Self.sliceFileMetadata: [:]]) throws -> ProcessOutput {
        let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "XCFrameworkSliceSelector: \(message)".intern()))
        return .init(outputValues: Dictionary(uniqueKeysWithValues: Self.outputPorts.map { ($0, error) }),
                     inputWireSpecs: inputWireSpecs)
    }
}
