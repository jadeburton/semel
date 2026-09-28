//
//  XcodeProjectFacts.swift
//  SemelApple
//
//  What a tool outside the engine needs to know about a project before the build:
//  `semel-swift prepare` writes a config whose target triple carries the deployment
//  version and the settings blocks the project's local packages read, and puts in place
//  the xcconfig files the project names, and asks here rather
//  than reading the project itself. The reading and the evaluation are the converter's;
//  these are the same questions, answered the same way, over the disk rather than over
//  wires.

import Foundation

public enum XcodeProjectFacts {

    /// The configuration the converter builds, and so the one whose xcconfig files count.
    static let configuration = "Debug"

    /// The `.xcconfig` files the project, its application target and the extensions the
    /// application embeds name for the built configuration, relative to the project's
    /// folder, in the order the converter reads them. Not the files those include: a
    /// file `prepare` has to put in place is one the project names. Empty when the
    /// project has no application.
    public static func xcconfigPaths(ofProjectAt project: URL) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return []
        }
        return read.xcconfigPaths(for: read.bundleTargets(of: application), configuration: configuration)
    }

    /// Every local package of the project, relative to the project's folder, as the
    /// converter finds them: the ones the project declares, and every folder directly in
    /// one of its synchronized folders that holds a `Package.swift`. Sorted. The packages
    /// Xcode resolves a product dependency among, so the ones whose languages decide the
    /// config `prepare` writes.
    public static func localPackagePaths(ofProjectAt project: URL) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        let folder = project.deletingLastPathComponent()
        return LocalPackageSearch(project: read) { relativePath in
            contents(ofFolderAt: folder.appendingPathComponent(relativePath).standardizedFileURL)
        }.packagePaths
    }

    /// A folder on disk as the search reads a folder manifest: its files and its
    /// subfolders by name, hidden ones left out as a push leaves them out. A folder that is
    /// not there holds nothing.
    static func contents(ofFolderAt folder: URL) -> LocalPackageSearch.Contents {
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        var contents = LocalPackageSearch.Contents()
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                contents.folders.append(child.lastPathComponent)
            } else {
                contents.files.append(child.lastPathComponent)
            }
        }
        return contents
    }

    /// The names the settings of the application and the extensions it embeds still
    /// reference after evaluation for `sdk`, with the xcconfig files read from beside the
    /// project when they are there: what a missing xcconfig would have to define. Sorted,
    /// each once. Empty when the project has no application.
    public static func undefinedReferences(ofProjectAt project: URL, sdk: String) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return []
        }
        let targets = read.bundleTargets(of: application)
        let expansions = try expansions(of: read.xcconfigPaths(for: targets, configuration: configuration),
                                        in: project.deletingLastPathComponent())
        var names = Set<String>()
        for target in targets {
            let settings = try XcodeBuildSettings.resolve(
                project: read, target: target, configuration: configuration, sdk: sdk,
                xcconfig: { expansions[$0]?.assignments },
                extra: ["TARGET_NAME": target.name])
            names.formUnion(settings.unresolvedReferences)
        }
        return names.sorted()
    }

    /// The application target's deployment target for the SDK named `sdk`
    /// (`iphonesimulator`, `macosx`), evaluated as the converter evaluates settings, with
    /// the xcconfig files read from beside the project when they are there. Nil when the
    /// project has no application or states no target.
    public static func deploymentTarget(ofProjectAt project: URL, sdk: String) throws -> String? {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = read.targets.first(where: \.isApplication) else {
            return nil
        }
        let expansions = try expansions(of: read.xcconfigPaths(for: application, configuration: configuration),
                                        in: project.deletingLastPathComponent())
        let settings = try XcodeBuildSettings.resolve(
            project: read, target: application, configuration: configuration, sdk: sdk,
            xcconfig: { expansions[$0]?.assignments },
            extra: ["TARGET_NAME": application.name])
        let key = sdk.hasPrefix("macosx") ? "MACOSX_DEPLOYMENT_TARGET" : "IPHONEOS_DEPLOYMENT_TARGET"
        return settings[key]
    }

    /// Each root xcconfig with its includes followed on disk, by its path relative to
    /// `folder`, the project's folder. A file that cannot be read is not there.
    static func expansions(of roots: [String], in folder: URL) throws -> [String: XcconfigExpansion] {
        var expansions: [String: XcconfigExpansion] = [:]
        for root in roots {
            expansions[root] = try XcconfigExpansion(root: root) { relativePath in
                let file = relativePath.hasPrefix("/")
                    ? URL(fileURLWithPath: relativePath)
                    : folder.appendingPathComponent(relativePath).standardizedFileURL
                guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                    return .absent
                }
                return .present(Xcconfig(parsing: text))
            }
        }
        return expansions
    }
}
