//
//  XcodeProject.swift
//  SemelApple
//
//  What a converter needs to know about an Xcode project, read out of `project.pbxproj`.
//  The file is a property list — the OpenStep form, which PropertyListSerialization reads —
//  holding one flat table of objects that reference each other by id. This resolves the
//  references once and keeps only what a build needs: the native targets, their settings
//  per configuration, the folders that are their sources, what they link and embed.
//  Nothing here evaluates a setting; `XcodeBuildSettings` does that.

import Foundation
import SemelNodeKit

struct XcodeProject {

    struct BuildConfiguration {
        let name: String
        let settings: [String: String]
        /// The `.xcconfig` this configuration is based on, relative to the project's
        /// folder, if any.
        let xcconfigPath: String?
    }

    /// A Xcode 16 synchronized folder: the folder is the target's sources and resources,
    /// less the exceptions, which are relative to it.
    struct SynchronizedFolder {
        let path: String
        let exceptions: [MembershipException]
        /// The folders in it, relative to it, that the group's `explicitFolders` names:
        /// each one item to Xcode, copied whole into the bundle's resources with what it
        /// holds kept as it is laid out, where any other plain folder is walked and its
        /// files flattened (NetNewsWire's `xcconfig` folder names `common`).
        var explicitFolders: [String] = []
        /// The owner's own flags for single sources, by path relative to the folder: the
        /// exception set's `additionalCompilerFlagsByRelativePath`, as the project file
        /// spells them (`-DPROBE_FLAG=7`), one string of words for each source.
        var compilerFlags: [String: String] = [:]

        /// Whether the file or folder at `relativePath` in the folder is left out. An
        /// entry naming a folder leaves out what is under it only when Xcode takes that
        /// folder as one item — a catalog, a bundle, a folder the group names in
        /// `explicitFolders` (NetNewsWire's iOS app leaves out `Resources/Assets.xcassets`).
        /// One naming a plain folder leaves out nothing under it: with `ExcludedFolder` or
        /// `ExcludedFolder/` among the owner's exceptions, Xcode 26.6 compiled a Swift file
        /// under it and copied a text file, and a second probe `Plain/Under.swift` (B-77).
        func excludes(_ relativePath: String) -> Bool {
            exceptions.contains { exception in
                guard let path = exception.path else {
                    return exception.matches(relativePath)
                }
                return exception.matches(relativePath)
                    || (relativePath.hasPrefix(path + "/") && takesAsOneItem(folder: path))
            }
        }

        /// Whether Xcode takes the folder at `relativePath` as one item rather than as a
        /// group whose files are members each by itself.
        func takesAsOneItem(folder relativePath: String) -> Bool {
            XcodeFormulaEmitter.folderRole(at: relativePath, explicitFolders: explicitFolders) != .group
        }

        /// The exceptions that leave out a path, for the Swift compiler, which walks the
        /// folder itself and reads each as a package's `exclude` is read — what is under
        /// it left out too. So an entry naming one of `folders` (what the folder holds, as
        /// walked) that Xcode takes as a group is not among them: Xcode leaves out nothing
        /// under it. A localized resource is never a source.
        func excludedPaths(folders: [String]) -> [String] {
            let groups = Set(folders.filter { !takesAsOneItem(folder: $0) })
            return exceptions.compactMap(\.path).filter { !groups.contains($0) }
        }
    }

    /// A copy-files phase a synchronized folder's file is put into as well as its own
    /// phase: an exception set of the kind `PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet`
    /// names the phase and the files. Established on Xcode 26.6 (B-77 item 2): `Copied.txt`,
    /// named for a phase copying to the resources' `Extra` folder, landed in both
    /// `Contents/Resources/` and `Contents/Resources/Extra/`, and `Support.txt`, for one
    /// copying to Shared Support, in `Contents/Resources/` and `Contents/SharedSupport/`.
    struct PhaseCopy: Equatable {
        /// The synchronized folder, relative to the project folder.
        let folder: String
        /// The file or folder, relative to the synchronized folder.
        let path: String
        let destination: CopyDestination
    }

    /// Where a copy-files phase copies to: the phase's `dstSubfolderSpec` and `dstPath`.
    struct CopyDestination: Equatable {
        /// Xcode's numbering: 1 the bundle itself (the wrapper), 6 executables, 7
        /// resources, 10 frameworks, 11 shared frameworks, 12 shared support, 13 plug-ins,
        /// 16 the products folder, 0 an absolute path.
        let subfolderSpec: Int
        /// The folder under it, `""` for none.
        let path: String
    }

    /// One entry of a synchronized folder's exception set, relative to the folder: a file
    /// the owning target leaves out, or one a target that does not own the folder takes.
    ///
    /// Most entries are a path. One that begins `/Localized/` is not: it names a localized
    /// resource, the way Xcode shows one in its navigator — one item standing for the file
    /// in every language folder beside it. `/Localized/ShareExtension/ShareViewController.xib`
    /// is `ShareExtension/<language>.lproj/ShareViewController.xib` in each `.lproj` folder
    /// there, and — since the resource is an Interface Builder file — the string tables
    /// that localize it, `ShareExtension/<language>.lproj/ShareViewController.strings` or
    /// `.xcstrings`. Established by building a project whose owner excludes
    /// `/Localized/Sub/Thing.xib` while a second target takes it and
    /// `/Localized/Sub/Plain.txt`: the owner lost `Base.lproj/Thing.xib` and
    /// `mul.lproj/Thing.xcstrings` and kept `de.lproj/Thing.txt` and `Base.lproj/Other.xib`;
    /// the second got `Base.lproj/Thing.nib`, the catalog's `es.lproj/Thing.strings`, and
    /// `Plain.txt` from both `en.lproj` and `de.lproj` (Xcode 26.6).
    enum MembershipException: Hashable {
        case path(String)
        /// The folder holding the `.lproj` folders, relative to the synchronized folder
        /// (empty for the synchronized folder itself), and the file's name.
        case localized(folder: String, name: String)

        static let localizedPrefix = "/Localized/"

        init(_ entry: String) {
            guard entry.hasPrefix(Self.localizedPrefix) else {
                // `ExcludedFolder/` names the folder `ExcludedFolder` names.
                self = .path(entry.hasSuffix("/") ? String(entry.dropLast()) : entry)
                return
            }
            var components = entry.dropFirst(Self.localizedPrefix.count).split(separator: "/").map(String.init)
            let name = components.popLast() ?? ""
            self = .localized(folder: components.joined(separator: "/"), name: name)
        }

        /// The entry as the project file spells it.
        var spelling: String {
            switch self {
            case .path(let path):
                return path
            case .localized(let folder, let name):
                return Self.localizedPrefix + (folder.isEmpty ? name : "\(folder)/\(name)")
            }
        }

        var path: String? {
            guard case .path(let path) = self else {
                return nil
            }
            return path
        }

        /// Whether the file or folder at `relativePath`, relative to the synchronized
        /// folder, is the one this entry names. A path names itself alone; whether what is
        /// under a folder goes with it is the folder's question (`SynchronizedFolder.excludes`).
        func matches(_ relativePath: String) -> Bool {
            switch self {
            case .path(let path):
                return relativePath == path
            case .localized(let folder, let name):
                var components = relativePath.split(separator: "/").map(String.init)
                guard components.count >= 2, let fileName = components.popLast(), let language = components.popLast(),
                      language.hasSuffix(".lproj"), components.joined(separator: "/") == folder else {
                    return false
                }
                return fileName == name || Self.localizes(fileName, interfaceFile: name)
            }
        }

        /// A string table localizing an Interface Builder file carries its name with the
        /// table's extension: `MainMenu.xcstrings` beside `MainMenu.xib`.
        private static func localizes(_ fileName: String, interfaceFile: String) -> Bool {
            let interface = interfaceFile as NSString
            let file = fileName as NSString
            return ["xib", "storyboard"].contains(interface.pathExtension)
                && ["strings", "xcstrings", "stringsdict"].contains(file.pathExtension)
                && file.deletingPathExtension == interface.deletingPathExtension
        }
    }

    /// What a target takes from a synchronized folder that is not its own: the folder,
    /// relative to the project folder, and the entry naming what it takes.
    struct Borrowed: Hashable {
        let folder: String
        let exception: MembershipException
        /// The borrowing target's own flags for the source, when its exception set gives
        /// it some (`additionalCompilerFlagsByRelativePath`).
        var compilerFlags: String?
    }

    enum PackageProduct: Equatable {
        /// A product of a package in the project's own tree — a `Packages/Timeline`
        /// wrapper, an `XCLocalSwiftPackageReference`, a package folder in a synchronized
        /// folder — which the project names by product only. Xcode finds the product by
        /// name among every local package of the project, and so does the formula: each
        /// local package's formula is included and defines `modules_<Product>()` for the
        /// products it vends (`LocalPackageSearch`).
        case local(product: String)
        /// A product of a remote package, with the repository the project declares.
        case remote(product: String, repositoryURL: String)

        var product: String {
            switch self {
            case .local(let product):     return product
            case .remote(let product, _): return product
            }
        }
    }

    /// One entry of a build phase: the file, and the platforms it is limited to — a
    /// multiplatform target marks an iOS-only file `platformFilters = (ios, )`, and a
    /// Mac build leaves it out. Empty means every platform.
    struct BuildFile: Equatable {
        let path: String
        let platformFilters: Set<String>
        /// A folder reference (`lastKnownFileType = folder`): a folder the resources phase
        /// copies whole, under its own name — NetNewsWire's `Themes/Sepia.nnwtheme`.
        let isFolderReference: Bool

        init(path: String, platformFilters: Set<String> = [], isFolderReference: Bool = false) {
            self.path = path
            self.platformFilters = platformFilters
            self.isFolderReference = isFolderReference
        }

        /// Whether the file is built for the SDK named, by Xcode's platform names.
        func isBuilt(forSDK sdk: String) -> Bool {
            platformFilters.isEmpty || platformFilters.contains(XcodeProject.platformName(forSDK: sdk))
        }
    }

    /// The platform a file filter names for an SDK: `ios` for both iPhone SDKs, `macos`
    /// for the Mac's.
    static func platformName(forSDK sdk: String) -> String {
        if sdk.hasPrefix("macosx") { return "macos" }
        if sdk.hasPrefix("iphone") { return "ios" }
        if sdk.hasPrefix("appletv") { return "tvos" }
        if sdk.hasPrefix("watch") { return "watchos" }
        if sdk.hasPrefix("xr") { return "visionos" }
        return sdk
    }

    struct Target {
        let name: String
        /// `com.apple.product-type.application`, `com.apple.product-type.app-extension`.
        let productType: String
        /// The product file's name: `Ice Cubes.app`, `IceCubesShareExtension.appex`.
        let productFileName: String
        let configurations: [BuildConfiguration]
        let synchronizedFolders: [SynchronizedFolder]
        let packageProducts: [PackageProduct]
        /// System frameworks from the frameworks phase, by name: `QuickLook`.
        let frameworks: [String]
        /// Product file names the copy-files phase embeds under `PlugIns`.
        let embeddedExtensions: [String]
        /// File references in the resources phase, relative to the project folder, each
        /// with the platforms it is limited to.
        let resourceFiles: [BuildFile]
        /// What this target takes from another target's synchronized folder — an
        /// exception set in that folder naming this target: a widget's sounds and strings
        /// from the app's folder, an intents extension's entities from the app's, a share
        /// extension's localized xib.
        var borrowed: [Borrowed] = []
        /// The package plugins the target runs, by product name: a target dependency on a
        /// `plugin:SwiftLint` product, CodeEdit's app. None is run (B-77).
        var plugins: [String] = []

        /// The borrowed entries that are paths, relative to the project folder.
        var borrowedFiles: [String] {
            borrowed.compactMap { entry in entry.exception.path.map { "\(entry.folder)/\($0)" } }
        }

        /// The borrowed entries that name a localized resource (`/Localized/…`), which only
        /// the lending folder's contents can turn into files.
        var borrowedLocalizedResources: [Borrowed] {
            borrowed.filter { $0.exception.path == nil }
        }

        /// The flags the target gives each borrowed source of its own, by path relative to
        /// the project folder.
        var borrowedCompilerFlags: [String: String] {
            var flags: [String: String] = [:]
            for entry in borrowed {
                if let path = entry.exception.path, let compilerFlags = entry.compilerFlags {
                    flags["\(entry.folder)/\(path)"] = compilerFlags
                }
            }
            return flags
        }

        /// What a synchronized folder's exception sets put into this target's copy-files
        /// phases, sorted.
        var phaseCopies: [PhaseCopy] = []
        /// The files in the sources phase, relative to the project folder, for a target
        /// that lists its files through groups rather than owning a synchronized folder
        /// (B-77), each with the platforms it is limited to. Empty for a folder-owning
        /// target, whose sources are its folder's.
        var sourceFiles: [BuildFile] = []

        /// The listed sources built for `sdk`, in order.
        func sourcePaths(forSDK sdk: String) -> [String] {
            sourceFiles.filter { $0.isBuilt(forSDK: sdk) }.map(\.path)
        }

        /// The resources phase's files built for `sdk`, in order.
        func resourcePaths(forSDK sdk: String) -> [String] {
            resourceFiles.filter { $0.isBuilt(forSDK: sdk) }.map(\.path)
        }

        var isApplication: Bool { productType == "com.apple.product-type.application" }
        var isExtension: Bool { productType == "com.apple.product-type.app-extension" }

        func configuration(named name: String) -> BuildConfiguration? {
            configurations.first { $0.name == name }
        }
    }

    let configurations: [BuildConfiguration]
    let targets: [Target]
    /// The project's development language, `en` when it names none: what Xcode gives a
    /// build as `DEVELOPMENT_LANGUAGE`.
    let developmentRegion: String
    /// Local packages the project declares, relative to the project folder: a folder
    /// wrapper among its file references (`Packages/Timeline`), or an
    /// `XCLocalSwiftPackageReference`'s `relativePath`. Not the packages Xcode finds in a
    /// synchronized folder, which the project file does not name: `LocalPackageSearch`
    /// adds those from the folders' contents.
    let localPackagePaths: [String]
    /// Every synchronized folder of the project, relative to the project folder, whether
    /// or not a target owns it: NetNewsWire's `Modules` belongs to no target and holds its
    /// seventeen packages.
    let synchronizedFolderPaths: [String]
    /// Remote packages the project declares, by repository URL.
    let remotePackageURLs: [String]

    func configuration(named name: String) -> BuildConfiguration? {
        configurations.first { $0.name == name }
    }

    /// The `.xcconfig` files the project and then `target` base the named configuration
    /// on, relative to the project's folder: the levels `XcodeBuildSettings` reads, in
    /// the order it reads them. Whether a file is there is the caller's question, and so
    /// are the files each includes.
    func xcconfigPaths(for target: Target, configuration name: String) -> [String] {
        [configuration(named: name), target.configuration(named: name)].compactMap { $0?.xcconfigPath }
    }

    /// The same for several targets, each file once, in the order first named.
    func xcconfigPaths(for targets: [Target], configuration name: String) -> [String] {
        var paths: [String] = []
        for path in targets.flatMap({ xcconfigPaths(for: $0, configuration: name) }) where !paths.contains(path) {
            paths.append(path)
        }
        return paths
    }

    /// The targets one build of `application` builds: the application, and the extensions
    /// it embeds, in the order it lists them.
    func bundleTargets(of application: Target) -> [Target] {
        [application] + application.embeddedExtensions.compactMap { name in
            targets.first { $0.productFileName == name && $0.isExtension }
        }
    }

    // MARK: - Which application a build is for (B-77)

    /// The application targets, in the project's order.
    var applications: [Target] {
        targets.filter(\.isApplication)
    }

    /// The application a build for `sdk` builds: the one whose `SDKROOT`, evaluated with
    /// `settings`, is of the SDK's platform family — `iphoneos` for an `iphonesimulator`
    /// build, since the simulator builds the iOS app — or, for one whose `SDKROOT` is
    /// `auto` (a multiplatform target), whose `SUPPORTED_PLATFORMS` names the SDK.
    /// NetNewsWire has a Mac app and an iOS app, both `NetNewsWire.app`, and only the
    /// platform tells them apart.
    ///
    /// An application that states neither setting is taken for any platform: Xcode writes
    /// `SDKROOT` into every target it creates, so only a hand-written project lacks it, and
    /// such a project has meant "build this one" whatever it was built for.
    ///
    /// `named`, the converter's `application` setting, picks one by name and is the only
    /// way past two applications for one platform, which is an error naming both rather
    /// than a guess.
    func application(forSDK sdk: String, named name: String?,
                     settings: (Target) throws -> XcodeBuildSettings) throws -> Target {
        let applications = self.applications
        if let name {
            guard let chosen = applications.first(where: { $0.name == name }) else {
                throw XcodeProjectError.noSuchApplication(name: name, applications: applications.map(\.name))
            }
            return chosen
        }
        var described: [String] = []
        var matching: [Target] = []
        var unstated: [Target] = []
        for application in applications {
            let evaluated = try settings(application)
            guard let platform = Self.platform(ofApplicationWith: evaluated) else {
                described.append("\(application.name) (any platform)")
                unstated.append(application)
                continue
            }
            described.append("\(application.name) (\(platform))")
            if Self.builds(sdk: sdk, forPlatform: evaluated) {
                matching.append(application)
            }
        }
        // One stating its platform wins over one stating none, which only a hand-written
        // project has.
        let chosen = matching.isEmpty ? unstated : matching
        guard chosen.count == 1, let application = chosen.first else {
            if chosen.isEmpty {
                throw XcodeProjectError.noApplicationForSDK(sdk: sdk, applications: described)
            }
            throw XcodeProjectError.severalApplicationsForSDK(sdk: sdk, applications: chosen.map(\.name))
        }
        return application
    }

    /// `iphoneos` for `iphonesimulator`, `iphonesimulator17.0` or
    /// `…/iPhoneSimulator.sdk`; `macosx` for `macosx`; a simulator SDK's family is its
    /// device SDK's (`xrsimulator` is `xros`, `watchsimulator` `watchos`).
    static func platformFamily(ofSDK sdk: String) -> String {
        var name = (sdk as NSString).lastPathComponent.lowercased()
        if name.hasSuffix(".sdk") {
            name = String(name.dropLast(".sdk".count))
        }
        name = String(name.prefix { $0.isLetter })
        if name.hasSuffix("simulator") {
            return String(name.dropLast("simulator".count)) + "os"
        }
        return name
    }

    /// What an application's settings say it is built for, for the error that names it:
    /// its `SDKROOT`, or for `auto` its `SUPPORTED_PLATFORMS`; nil when it states neither.
    static func platform(ofApplicationWith settings: XcodeBuildSettings) -> String? {
        let sdkRoot = settings["SDKROOT"] ?? ""
        guard sdkRoot.isEmpty || sdkRoot == "auto" else {
            return platformFamily(ofSDK: sdkRoot)
        }
        let supported = settings["SUPPORTED_PLATFORMS"] ?? ""
        return supported.isEmpty ? nil : supported
    }

    /// Whether the settings build for `sdk`: an `SDKROOT` of its family, or `auto` with
    /// `SUPPORTED_PLATFORMS` naming it or its family.
    static func builds(sdk: String, forPlatform settings: XcodeBuildSettings) -> Bool {
        let family = platformFamily(ofSDK: sdk)
        let sdkRoot = settings["SDKROOT"] ?? ""
        guard sdkRoot.isEmpty || sdkRoot == "auto" else {
            return platformFamily(ofSDK: sdkRoot) == family
        }
        let supported = (settings["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").map(String.init)
        return supported.contains { platformFamily(ofSDK: $0) == family }
    }

    // MARK: - Reading

    init(pbxproj data: Data) throws {
        guard let document = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = document["objects"] as? [String: [String: Any]],
              let rootID = document["rootObject"] as? String,
              let root = objects[rootID] else {
            throw XcodeProjectError.notAProject
        }
        let reader = Reader(objects: objects)

        configurations = try reader.configurations(listID: root["buildConfigurationList"] as? String)
        developmentRegion = root["developmentRegion"] as? String ?? "en"

        // A local package is declared as a folder wrapper among the project's file
        // references, resolved through its groups, or — Xcode 15 onwards — as a package
        // reference with a path relative to the project's folder. Remote ones are declared
        // objects. None says which products it vends — the package's own manifest does,
        // which the package's converter reads.
        localPackagePaths = Set(objects.compactMap { id, object -> String? in
            switch object["isa"] as? String {
            case "PBXFileReference" where object["lastKnownFileType"] as? String == "wrapper":
                return reader.path(of: id)
            case "XCLocalSwiftPackageReference":
                return object["relativePath"] as? String
            default:
                return nil
            }
        }).sorted()
        synchronizedFolderPaths = Set(objects.compactMap { id, object -> String? in
            object["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" ? reader.path(of: id) : nil
        }).sorted()
        remotePackageURLs = objects.values
            .filter { $0["isa"] as? String == "XCRemoteSwiftPackageReference" }
            .compactMap { $0["repositoryURL"] as? String }
            .sorted()

        let targetIDs = (root["targets"] as? [String] ?? []).filter { objects[$0]?["isa"] as? String == "PBXNativeTarget" }
        var targets = try targetIDs.compactMap { targetID -> Target? in
            guard let target = objects[targetID] else {
                return nil
            }
            return try reader.target(target, id: targetID)
        }

        // A second pass for what a target takes from a folder that is not its own: an
        // exception set in that folder naming the target lists the files it borrows. The
        // folder may belong to another target, or to none — Xcode leaves a folder
        // unowned when every target that uses it names its files this way, which is how
        // IceCubes' notification and share extensions get their sources. It may also have
        // several owners — NetNewsWire's `Shared` is both apps' — and a set naming any of
        // them says what that owner leaves out, not what it borrows.
        var ownersOfGroup: [String: Set<String>] = [:]
        for ownerID in targetIDs {
            for groupID in objects[ownerID]?["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                ownersOfGroup[groupID, default: []].insert(ownerID)
            }
        }
        // A set of the other kind names a build phase rather than a target: its files go
        // into that phase as well — a copy-files phase copies them where it says — which
        // is the business of the target whose phase it is.
        var copyPhases: [String: (targetIndex: Int, destination: CopyDestination)] = [:]
        for (targetIndex, targetID) in targetIDs.enumerated() {
            for phaseID in objects[targetID]?["buildPhases"] as? [String] ?? [] {
                if let phase = objects[phaseID], let destination = Reader.copyDestination(of: phase) {
                    copyPhases[phaseID] = (targetIndex, destination)
                }
            }
        }
        for (groupID, group) in objects where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            guard let path = reader.path(of: groupID) else {
                continue
            }
            for exceptionID in group["exceptions"] as? [String] ?? [] {
                guard let exceptions = objects[exceptionID] else {
                    continue
                }
                if exceptions["isa"] as? String == Reader.buildPhaseExceptionSet {
                    // ISSUE: a set naming a sources or resources phase is not read; only a
                    // copy-files phase says where its files go, and no project met names
                    // another kind.
                    guard let phaseID = exceptions["buildPhase"] as? String, let phase = copyPhases[phaseID] else {
                        continue
                    }
                    for entry in exceptions["membershipExceptions"] as? [String] ?? [] {
                        guard case .path(let entryPath) = MembershipException(entry) else {
                            continue
                        }
                        targets[phase.targetIndex].phaseCopies.append(PhaseCopy(folder: path, path: entryPath, destination: phase.destination))
                    }
                    continue
                }
                guard exceptions["isa"] as? String == Reader.buildFileExceptionSet,
                      let borrowerID = exceptions["target"] as? String, ownersOfGroup[groupID]?.contains(borrowerID) != true,
                      let borrowerIndex = targetIDs.firstIndex(of: borrowerID) else {
                    continue
                }
                let flags = exceptions["additionalCompilerFlagsByRelativePath"] as? [String: String] ?? [:]
                for entry in exceptions["membershipExceptions"] as? [String] ?? [] {
                    let exception = MembershipException(entry)
                    targets[borrowerIndex].borrowed.append(Borrowed(folder: path, exception: exception,
                                                                    compilerFlags: exception.path.flatMap { flags[$0] }))
                }
            }
        }
        for index in targets.indices {
            targets[index].borrowed.sort { ($0.folder, $0.exception.spelling) < ($1.folder, $1.exception.spelling) }
            targets[index].phaseCopies.sort {
                ($0.folder, $0.path, $0.destination.subfolderSpec, $0.destination.path)
                    < ($1.folder, $1.path, $1.destination.subfolderSpec, $1.destination.path)
            }
        }
        self.targets = targets
    }

    /// Resolves object references while reading; nothing of it survives the init.
    private struct Reader {
        let objects: [String: [String: Any]]

        /// The exception set naming a target: the owner's exclusions, or what a target that
        /// does not own the folder takes from it, and the flags for single sources.
        static let buildFileExceptionSet = "PBXFileSystemSynchronizedBuildFileExceptionSet"
        /// The exception set naming a build phase, which its files join as well.
        static let buildPhaseExceptionSet = "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"
        /// How a product dependency names a package's plugin rather than a library.
        static let pluginProductPrefix = "plugin:"

        /// Where a copy-files phase copies to; nil for any other phase.
        static func copyDestination(of phase: [String: Any]) -> CopyDestination? {
            guard phase["isa"] as? String == "PBXCopyFilesBuildPhase" else {
                return nil
            }
            let spec = phase["dstSubfolderSpec"]
            guard let subfolderSpec = (spec as? String).flatMap(Int.init) ?? (spec as? Int) else {
                return nil
            }
            return CopyDestination(subfolderSpec: subfolderSpec, path: phase["dstPath"] as? String ?? "")
        }

        /// The group each group and file reference is a child of: what a `<group>`
        /// relative path is relative to.
        let parentOf: [String: String]

        /// The repository of each product some product dependency of the project names
        /// with its remote package, by product name — only where one repository does.
        let remoteRepositoryByProduct: [String: String]

        init(objects: [String: [String: Any]]) {
            self.objects = objects
            var parentOf: [String: String] = [:]
            var repositoriesByProduct: [String: Set<String>] = [:]
            for (objectID, object) in objects {
                for childID in object["children"] as? [String] ?? [] {
                    parentOf[childID] = objectID
                }
                guard object["isa"] as? String == "XCSwiftPackageProductDependency",
                      let product = object["productName"] as? String,
                      let packageID = object["package"] as? String,
                      let url = objects[packageID]?["repositoryURL"] as? String else {
                    continue
                }
                repositoriesByProduct[product, default: []].insert(url)
            }
            self.parentOf = parentOf
            self.remoteRepositoryByProduct = repositoriesByProduct.compactMapValues { $0.count == 1 ? $0.first : nil }
        }

        /// A target's package products, each once. A dependency that names no package is
        /// a product Xcode finds by name in the workspace's package graph, where every
        /// product has one identity (`PACKAGE-PRODUCT:<name>`), remote packages' included;
        /// so one that another dependency names with its remote package is that package's
        /// — CodeEdit links `CodeEditSourceEditor` through eight dependencies, five left
        /// with no package from when it was a local one. Any other is a local package's.
        /// A `plugin:` product is not linked: it is a plugin the target would run.
        func packageProducts(dependencyIDs: [String]) -> [PackageProduct] {
            var products: [PackageProduct] = []
            for id in dependencyIDs {
                guard let dependency = object(id), let product = dependency["productName"] as? String,
                      !product.hasPrefix(Self.pluginProductPrefix),
                      !products.contains(where: { $0.product == product }) else {
                    continue
                }
                if let package = object(dependency["package"] as? String), let url = package["repositoryURL"] as? String {
                    products.append(.remote(product: product, repositoryURL: url))
                } else if let url = remoteRepositoryByProduct[product] {
                    products.append(.remote(product: product, repositoryURL: url))
                } else {
                    products.append(.local(product: product))
                }
            }
            return products
        }

        func object(_ id: String?) -> [String: Any]? {
            id.flatMap { objects[$0] }
        }

        /// The path of a file reference or group relative to the project's folder, the
        /// way Xcode resolves it: its own `path` under each parent group's, up to the main
        /// group — or up to a level whose `sourceTree` is the source root, which stands
        /// on its own. Nil for a reference outside the tree: a product, an SDK framework,
        /// an absolute path. A group named for the reader with `path = .` adds nothing.
        func path(of id: String) -> String? {
            var components: [String] = []
            var current: String? = id
            while let currentID = current, let object = objects[currentID] {
                if let path = object["path"] as? String, !path.isEmpty, path != "." {
                    components.insert(path, at: 0)
                }
                switch object["sourceTree"] as? String ?? "<group>" {
                case "<group>":     current = parentOf[currentID]
                case "SOURCE_ROOT": current = nil
                default:            return nil
                }
            }
            return components.isEmpty ? nil : components.joined(separator: "/")
        }

        /// The files one build-phase entry stands for: the file it references, or — for a
        /// localized resource, which Xcode keeps as a variant group over one file per
        /// `.lproj` — every variant's file.
        func paths(ofFileReference id: String) -> [String] {
            guard let reference = objects[id] else {
                return []
            }
            if reference["isa"] as? String == "PBXVariantGroup" {
                return (reference["children"] as? [String] ?? []).compactMap { path(of: $0) }
            }
            return path(of: id).map { [$0] } ?? []
        }

        /// A file reference to a plain folder, which Xcode copies whole: `folder` is the
        /// type of one, where a catalog is `folder.assetcatalog` and a group is no file
        /// reference at all.
        func isFolderReference(_ id: String) -> Bool {
            guard let reference = objects[id], reference["isa"] as? String == "PBXFileReference" else {
                return false
            }
            return (reference["lastKnownFileType"] as? String ?? reference["explicitFileType"] as? String) == "folder"
        }

        func configurations(listID: String?) throws -> [BuildConfiguration] {
            guard let list = object(listID) else {
                return []
            }
            return (list["buildConfigurations"] as? [String] ?? []).compactMap { id -> BuildConfiguration? in
                guard let configuration = object(id), let name = configuration["name"] as? String else {
                    return nil
                }
                let settings = (configuration["buildSettings"] as? [String: Any] ?? [:])
                    .compactMapValues { Self.settingString($0) }
                return BuildConfiguration(name: name, settings: settings, xcconfigPath: xcconfigPath(of: configuration))
            }
        }

        /// The file a configuration is based on, relative to the project's folder: a file
        /// reference, resolved through its groups — or, since Xcode 16, a path relative to
        /// an anchor, a synchronized folder that holds the file without a reference of
        /// its own. NetNewsWire bases every configuration on a file in its `xcconfig`
        /// folder this way.
        func xcconfigPath(of configuration: [String: Any]) -> String? {
            if let referenceID = configuration["baseConfigurationReference"] as? String {
                return path(of: referenceID)
            }
            guard let anchorID = configuration["baseConfigurationReferenceAnchor"] as? String,
                  let relativePath = configuration["baseConfigurationReferenceRelativePath"] as? String else {
                return nil
            }
            guard let anchorPath = path(of: anchorID) else {
                return nil
            }
            return "\(anchorPath)/\(relativePath)"
        }

        /// A setting is a string, or a list Xcode joins with spaces when it reads it.
        static func settingString(_ value: Any) -> String? {
            switch value {
            case let string as String: return string
            case let list as [String]: return list.joined(separator: " ")
            default: return nil
            }
        }

        func target(_ target: [String: Any], id: String) throws -> Target {
            let name = target["name"] as? String ?? ""
            let productFileName = object(target["productReference"] as? String)?["path"] as? String ?? name

            // The products the target links: its `packageProductDependencies`, and every
            // product its frameworks phase lists, which is what Xcode links from — CodeEdit's
            // app links LanguageServerProtocol and LanguageClient through the phase alone.
            var productDependencyIDs = target["packageProductDependencies"] as? [String] ?? []
            var frameworks: [String] = []
            var embeddedExtensions: [String] = []
            var sourceFiles: [BuildFile] = []
            var resourceFiles: [BuildFile] = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = object(phaseID), let isa = phase["isa"] as? String else {
                    continue
                }
                let buildFiles = (phase["files"] as? [String] ?? []).compactMap { object($0) }
                let fileRefIDs = buildFiles.compactMap { $0["fileRef"] as? String }
                let fileRefs = fileRefIDs.compactMap { object($0) }
                // Each build file's paths with the platforms the entry is limited to:
                // `platformFilter = ios` or `platformFilters = (ios, maccatalyst)`.
                let listed: [BuildFile] = buildFiles.flatMap { buildFile -> [BuildFile] in
                    guard let fileRefID = buildFile["fileRef"] as? String else {
                        return []
                    }
                    var filters = Set(buildFile["platformFilters"] as? [String] ?? [])
                    if let single = buildFile["platformFilter"] as? String {
                        filters.insert(single)
                    }
                    let isFolderReference = isFolderReference(fileRefID)
                    return paths(ofFileReference: fileRefID).map {
                        BuildFile(path: $0, platformFilters: filters, isFolderReference: isFolderReference)
                    }
                }
                switch isa {
                case "PBXFrameworksBuildPhase":
                    frameworks += fileRefs
                        .compactMap { $0["path"] as? String }
                        .filter { $0.hasSuffix(".framework") }
                        .map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".framework", with: "") }
                    productDependencyIDs += buildFiles.compactMap { $0["productRef"] as? String }
                case "PBXCopyFilesBuildPhase":
                    // dstSubfolderSpec 13 is PlugIns: where an app embeds its extensions.
                    let destination = (phase["dstSubfolderSpec"] as? String) ?? (phase["dstSubfolderSpec"] as? Int).map(String.init)
                    if destination == "13" {
                        embeddedExtensions += fileRefs.compactMap { $0["path"] as? String }
                    }
                case "PBXSourcesBuildPhase":
                    // A target that lists its files rather than owning a folder (B-77):
                    // each resolved through its groups to a path under the project.
                    sourceFiles += listed
                case "PBXResourcesBuildPhase":
                    resourceFiles += listed
                default:
                    break
                }
            }

            // An exception set names its target: for the folder's own target the files
            // listed are left out, and a set naming another target says what that target
            // takes from here, which is not this target's business; nor is a set naming a
            // build phase, read with the phase's target.
            let synchronizedFolders = (target["fileSystemSynchronizedGroups"] as? [String] ?? []).compactMap { groupID -> SynchronizedFolder? in
                guard let group = object(groupID), let path = path(of: groupID) else {
                    return nil
                }
                let sets = (group["exceptions"] as? [String] ?? [])
                    .compactMap { object($0) }
                    .filter { $0["isa"] as? String == Self.buildFileExceptionSet && $0["target"] as? String == id }
                let exceptions = sets.flatMap { $0["membershipExceptions"] as? [String] ?? [] }
                var compilerFlags: [String: String] = [:]
                for set in sets {
                    compilerFlags.merge(set["additionalCompilerFlagsByRelativePath"] as? [String: String] ?? [:]) { _, later in later }
                }
                return SynchronizedFolder(path: path, exceptions: exceptions.sorted().map(MembershipException.init),
                                          explicitFolders: (group["explicitFolders"] as? [String] ?? []).sorted(),
                                          compilerFlags: compilerFlags)
            }

            var built = Target(name: name,
                               productType: target["productType"] as? String ?? "",
                               productFileName: productFileName,
                               configurations: try configurations(listID: target["buildConfigurationList"] as? String),
                               synchronizedFolders: synchronizedFolders,
                               packageProducts: packageProducts(dependencyIDs: productDependencyIDs),
                               frameworks: frameworks.sorted(),
                               embeddedExtensions: embeddedExtensions.sorted(),
                               resourceFiles: resourceFiles.sorted { $0.path < $1.path },
                               sourceFiles: sourceFiles.sorted { $0.path < $1.path })
            // A plugin is a target dependency on a product Xcode names `plugin:<name>`.
            built.plugins = (target["dependencies"] as? [String] ?? []).compactMap { dependencyID -> String? in
                guard let productName = object(object(dependencyID)?["productRef"] as? String)?["productName"] as? String,
                      productName.hasPrefix(Self.pluginProductPrefix) else {
                    return nil
                }
                return String(productName.dropFirst(Self.pluginProductPrefix.count))
            }.sorted()
            return built
        }
    }
}

enum XcodeProjectError: Error, CustomStringConvertible, ErrorConditionConvertible {
    case notAProject
    case noSuchTarget(String)
    /// A target with no synchronized folder, no listed sources and no borrowed sources.
    case targetHasNoSources(String)
    case noSuchConfiguration(String, available: [String])
    /// Listed sources the converter does not compile: Objective-C, C, Metal, a Core Data
    /// model in the sources phase. Named, so the reader knows what the build would need.
    case unsupportedSources(target: String, files: [String])
    /// A target that runs build-tool plugins and has no source of its own: what it would
    /// compile is what the plugins generate, and none is run (B-77).
    case sourcesOnlyFromPlugins(target: String, plugins: [String])
    /// No application builds for the SDK; each is named with the platform it does build for.
    case noApplicationForSDK(sdk: String, applications: [String])
    /// More than one application builds for the SDK, and nothing says which.
    case severalApplicationsForSDK(sdk: String, applications: [String])
    /// The converter's `application` names no application target.
    case noSuchApplication(name: String, applications: [String])

    var description: String {
        switch self {
        case .noApplicationForSDK(let sdk, let applications):
            guard !applications.isEmpty else {
                return "the project has no application target"
            }
            return "no application target builds for \(sdk): the project has \(applications.joined(separator: ", "))"
        case .severalApplicationsForSDK(let sdk, let applications):
            return "\(applications.count) application targets build for \(sdk): \(applications.joined(separator: ", ")); "
                 + "name the one to build with application: '<name>' on XcodeProjectConverter, or --application <name> to prepare"
        case .noSuchApplication(let name, let applications):
            return "the project has no application target named '\(name)'; it has \(applications.isEmpty ? "none" : applications.joined(separator: ", "))"
        case .notAProject:
            return "not a project.pbxproj: no objects table and root object"
        case .noSuchTarget(let name):
            return "the project has no target named '\(name)'"
        case .targetHasNoSources(let name):
            return "\(name): no synchronized folder, no listed sources and no borrowed sources"
        case .unsupportedSources(let target, let files):
            return "\(target): sources that are not Swift are not compiled yet: \(files.joined(separator: ", "))"
        case .sourcesOnlyFromPlugins(let target, let plugins):
            return "\(target) has no source of its own, only what its build-tool plugins would generate — "
                 + "\(plugins.joined(separator: ", ")) — and build-tool plugins are not run (B-77), so it cannot be compiled"
        case .noSuchConfiguration(let name, let available):
            return "the project has no configuration named '\(name)'; it has: \(available.joined(separator: ", "))"
        }
    }

    var errorCondition: ErrorCondition {
        switch self {
        case .notAProject:                                   return .notAProject
        case .noSuchTarget(let name):                        return .noSuchTarget(name: name)
        case .targetHasNoSources(let name):                  return .targetHasNoSources(name: name)
        case .noSuchConfiguration(let name, let available):  return .noSuchConfiguration(name: name, available: available)
        case .unsupportedSources(let target, let files):     return .unsupportedSources(target: target, files: files)
        case .sourcesOnlyFromPlugins(let target, let plugins):
            return .sourcesOnlyFromPlugins(package: nil, target: target, plugins: plugins)
        case .noApplicationForSDK(let sdk, let applications):
            return applications.isEmpty ? .noApplicationTarget : .noApplicationForSDK(sdk: sdk, applications: applications)
        case .severalApplicationsForSDK(let sdk, let applications):
            return .severalApplicationsForSDK(sdk: sdk, applications: applications)
        case .noSuchApplication(let name, let applications): return .noSuchApplication(name: name, applications: applications)
        }
    }
}
