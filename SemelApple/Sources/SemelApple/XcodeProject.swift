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

struct XcodeProject {

    struct BuildConfiguration {
        let name: String
        let settings: [String: String]
        /// The `.xcconfig` this configuration is based on, relative to the project's
        /// folder, if any.
        let xcconfigPath: String?
    }

    /// A Xcode 16 synchronized folder: the folder is the target's sources and resources,
    /// less the exceptions, which are paths relative to it.
    struct SynchronizedFolder {
        let path: String
        let exceptions: [String]
    }

    enum PackageProduct: Equatable {
        /// A product of a package in the project's own tree — a `Packages/Timeline`
        /// wrapper — which the project names by product only.
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

        init(path: String, platformFilters: Set<String> = []) {
            self.path = path
            self.platformFilters = platformFilters
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
        /// Files this target takes from another target's synchronized folder — an
        /// exception set in that folder naming this target — relative to the project
        /// folder: a widget's sounds and strings from the app's folder, an intents
        /// extension's entities from the app's.
        var borrowedFiles: [String] = []
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
    /// Local packages the project references as folder wrappers, relative to the project
    /// folder: `Packages/Timeline`.
    let localPackagePaths: [String]
    /// Remote packages the project declares, by repository URL.
    let remotePackageURLs: [String]

    func configuration(named name: String) -> BuildConfiguration? {
        configurations.first { $0.name == name }
    }

    /// The `.xcconfig` files the project and then `target` base the named configuration
    /// on, relative to the project's folder: the layers `XcodeBuildSettings` reads, in
    /// the order it reads them. Whether a file is there is the caller's question.
    func xcconfigPaths(for target: Target, configuration name: String) -> [String] {
        [configuration(named: name), target.configuration(named: name)].compactMap { $0?.xcconfigPath }
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

        // Local packages are folder wrappers among the project's file references; remote
        // ones are declared objects. Neither says which products it vends — the
        // package's own manifest does, which the package's converter reads.
        localPackagePaths = objects.values
            .filter { $0["isa"] as? String == "PBXFileReference" && $0["lastKnownFileType"] as? String == "wrapper" }
            .compactMap { $0["path"] as? String }
            .sorted()
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
        // IceCubes' notification and share extensions get their sources.
        var ownerOfGroup: [String: String] = [:]
        for ownerID in targetIDs {
            for groupID in objects[ownerID]?["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                ownerOfGroup[groupID] = ownerID
            }
        }
        for (groupID, group) in objects where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            guard let path = group["path"] as? String else {
                continue
            }
            for exceptionID in group["exceptions"] as? [String] ?? [] {
                guard let exceptions = objects[exceptionID],
                      let borrowerID = exceptions["target"] as? String, borrowerID != ownerOfGroup[groupID],
                      let borrowerIndex = targetIDs.firstIndex(of: borrowerID) else {
                    continue
                }
                for file in exceptions["membershipExceptions"] as? [String] ?? [] {
                    targets[borrowerIndex].borrowedFiles.append("\(path)/\(file)")
                }
            }
        }
        for index in targets.indices {
            targets[index].borrowedFiles.sort()
        }
        self.targets = targets
    }

    /// Resolves object references while reading; nothing of it survives the init.
    private struct Reader {
        let objects: [String: [String: Any]]

        /// The group each group and file reference is a child of: what a `<group>`
        /// relative path is relative to.
        let parentOf: [String: String]

        init(objects: [String: [String: Any]]) {
            self.objects = objects
            var parentOf: [String: String] = [:]
            for (groupID, group) in objects {
                for childID in group["children"] as? [String] ?? [] {
                    parentOf[childID] = groupID
                }
            }
            self.parentOf = parentOf
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
                let xcconfig = object(configuration["baseConfigurationReference"] as? String)?["path"] as? String
                return BuildConfiguration(name: name, settings: settings, xcconfigPath: xcconfig)
            }
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

            var packageProducts: [PackageProduct] = []
            for id in target["packageProductDependencies"] as? [String] ?? [] {
                guard let dependency = object(id), let product = dependency["productName"] as? String else {
                    continue
                }
                if let package = object(dependency["package"] as? String), let url = package["repositoryURL"] as? String {
                    packageProducts.append(.remote(product: product, repositoryURL: url))
                } else {
                    packageProducts.append(.local(product: product))
                }
            }

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
                    return paths(ofFileReference: fileRefID).map { BuildFile(path: $0, platformFilters: filters) }
                }
                switch isa {
                case "PBXFrameworksBuildPhase":
                    frameworks += fileRefs
                        .compactMap { $0["path"] as? String }
                        .filter { $0.hasSuffix(".framework") }
                        .map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".framework", with: "") }
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
            // takes from here, which is not this target's business.
            let synchronizedFolders = (target["fileSystemSynchronizedGroups"] as? [String] ?? []).compactMap { groupID -> SynchronizedFolder? in
                guard let group = object(groupID), let path = group["path"] as? String else {
                    return nil
                }
                let exceptions = (group["exceptions"] as? [String] ?? [])
                    .compactMap { object($0) }
                    .filter { ($0["target"] as? String).map { $0 == id } ?? true }
                    .compactMap { $0["membershipExceptions"] as? [String] }
                    .flatMap { $0 }
                return SynchronizedFolder(path: path, exceptions: exceptions.sorted())
            }

            return Target(name: name,
                          productType: target["productType"] as? String ?? "",
                          productFileName: productFileName,
                          configurations: try configurations(listID: target["buildConfigurationList"] as? String),
                          synchronizedFolders: synchronizedFolders,
                          packageProducts: packageProducts,
                          frameworks: frameworks.sorted(),
                          embeddedExtensions: embeddedExtensions.sorted(),
                          resourceFiles: resourceFiles.sorted { $0.path < $1.path },
                          sourceFiles: sourceFiles.sorted { $0.path < $1.path })
        }
    }
}

enum XcodeProjectError: Error, CustomStringConvertible {
    case notAProject
    case noSuchTarget(String)
    case noSuchConfiguration(String, available: [String])
    /// Listed sources the converter does not compile: Objective-C, C, Metal, a Core Data
    /// model in the sources phase. Named, so the reader knows what the build would need.
    case unsupportedSources(target: String, files: [String])

    var description: String {
        switch self {
        case .notAProject:
            return "not a project.pbxproj: no objects table and root object"
        case .noSuchTarget(let name):
            return "the project has no target named '\(name)'"
        case .unsupportedSources(let target, let files):
            return "\(target): sources that are not Swift are not compiled yet: \(files.joined(separator: ", "))"
        case .noSuchConfiguration(let name, let available):
            return "the project has no configuration named '\(name)'; it has: \(available.joined(separator: ", "))"
        }
    }
}
