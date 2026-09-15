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
        /// File references in the resources phase, relative to the project folder.
        let resourceFiles: [String]

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

        targets = try (root["targets"] as? [String] ?? []).compactMap { targetID -> Target? in
            guard let target = objects[targetID], target["isa"] as? String == "PBXNativeTarget" else {
                return nil
            }
            return try reader.target(target, id: targetID)
        }
    }

    /// Resolves object references while reading; nothing of it survives the init.
    private struct Reader {
        let objects: [String: [String: Any]]

        func object(_ id: String?) -> [String: Any]? {
            id.flatMap { objects[$0] }
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
            var resourceFiles: [String] = []
            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = object(phaseID), let isa = phase["isa"] as? String else {
                    continue
                }
                let fileRefs = (phase["files"] as? [String] ?? [])
                    .compactMap { object($0)?["fileRef"] as? String }
                    .compactMap { object($0) }
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
                case "PBXResourcesBuildPhase":
                    resourceFiles += fileRefs.compactMap { $0["path"] as? String }
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
                          resourceFiles: resourceFiles.sorted())
        }
    }
}

enum XcodeProjectError: Error, CustomStringConvertible {
    case notAProject
    case noSuchTarget(String)
    case noSuchConfiguration(String, available: [String])

    var description: String {
        switch self {
        case .notAProject:
            return "not a project.pbxproj: no objects table and root object"
        case .noSuchTarget(let name):
            return "the project has no target named '\(name)'"
        case .noSuchConfiguration(let name, let available):
            return "the project has no configuration named '\(name)'; it has: \(available.joined(separator: ", "))"
        }
    }
}
