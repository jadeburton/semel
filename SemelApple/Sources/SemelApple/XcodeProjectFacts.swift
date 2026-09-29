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
import SemelNodeKit

public enum XcodeProjectFacts {

    /// The configuration the converter builds, and so the one whose xcconfig files count.
    static let configuration = "Debug"

    /// The `.xcconfig` files the project, each application target and the extensions each
    /// embeds name for the built configuration, relative to the project's folder, in the
    /// order the converter reads them. Not the files those include: a file `prepare` has to
    /// put in place is one the project names. Every application's, not only the one the
    /// platform picks: the pick is made by evaluating those files, so they are put in place
    /// before it. Empty when the project has no application.
    public static func xcconfigPaths(ofProjectAt project: URL) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        return read.xcconfigPaths(for: read.applications.flatMap(read.bundleTargets(of:)), configuration: configuration)
    }

    /// The application a build for `sdk` builds, as the converter picks it — by the
    /// `SDKROOT` its settings evaluate to, with the xcconfig files read from beside the
    /// project — or the one `named`. Nil when the project has no application.
    static func application(of read: XcodeProject, in folder: URL, sdk: String, named name: String?) throws -> XcodeProject.Target? {
        guard !read.applications.isEmpty else {
            return nil
        }
        let expansions = try expansions(of: read.xcconfigPaths(for: read.applications, configuration: configuration), in: folder)
        return try read.application(forSDK: sdk, named: name) { target in
            try XcodeBuildSettings.resolve(project: read, target: target, configuration: configuration, sdk: sdk,
                                           xcconfig: { expansions[$0]?.assignments },
                                           extra: ["TARGET_NAME": target.name])
        }
    }

    /// The name of the application a build for `sdk` builds, for `prepare` to say. Nil when
    /// the project has none.
    public static func applicationName(ofProjectAt project: URL, sdk: String, named name: String? = nil) throws -> String? {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        return try application(of: try XcodeProject(pbxproj: data), in: project.deletingLastPathComponent(), sdk: sdk, named: name)?.name
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
    public static func undefinedReferences(ofProjectAt project: URL, sdk: String, application name: String? = nil) throws -> [String] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = try application(of: read, in: project.deletingLastPathComponent(), sdk: sdk, named: name) else {
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
    public static func deploymentTarget(ofProjectAt project: URL, sdk: String, application name: String? = nil) throws -> String? {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        guard let application = try application(of: read, in: project.deletingLastPathComponent(), sdk: sdk, named: name) else {
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

    // MARK: - What the application's targets compile

    /// What the application and the extensions it embeds hold that decides which tools the
    /// formula names beyond Swift's: a C-family source, compiled through clang, and a xib or
    /// a storyboard, compiled by ibtool (B-77).
    public struct CompiledSources: Equatable {
        public var hasCFamilySources = false
        public var hasInterfaceBuilderDocuments = false

        public init(hasCFamilySources: Bool = false, hasInterfaceBuilderDocuments: Bool = false) {
            self.hasCFamilySources            = hasCFamilySources
            self.hasInterfaceBuilderDocuments = hasInterfaceBuilderDocuments
        }
    }

    /// Read from the disk as the converter reads its wires: each bundle target's
    /// synchronized folders to the bottom less their exceptions, hidden folders and
    /// catalogs left out, and what the targets list or borrow. None when the project has no
    /// application.
    public static func compiledSources(ofProjectAt project: URL, sdk: String, application name: String? = nil) throws -> CompiledSources {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        let folder = project.deletingLastPathComponent()
        guard let application = try application(of: read, in: folder, sdk: sdk, named: name) else {
            return CompiledSources()
        }
        var paths: [String] = []
        for target in read.bundleTargets(of: application) {
            for synchronized in target.synchronizedFolders {
                let root = folder.appendingPathComponent(synchronized.path, isDirectory: true)
                paths += files(under: root).filter { !synchronized.excludes($0) }
            }
            paths += target.sourcePaths(forSDK: sdk) + target.resourcePaths(forSDK: sdk) + target.borrowedFiles
        }
        let hasInterfaceBuilderDocuments = paths.contains { path in
            guard case .interfaceBuilder = XcodeFormulaEmitter.resource(at: path) else {
                return false
            }
            return true
        }
        return CompiledSources(hasCFamilySources: paths.contains(where: XcodeFormulaEmitter.isCFamilySource),
                               hasInterfaceBuilderDocuments: hasInterfaceBuilderDocuments)
    }

    /// Every file under `root` at any depth, relative to it, hidden entries and what a
    /// catalog holds left out, as the converter's walk leaves them out.
    static func files(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return []
        }
        var found: [String] = []
        while let path = enumerator.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix(".") || XcodeProjectConverter.isCompiledWhole(name) {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.fileAttributes?[.type] as? FileAttributeType != .typeDirectory {
                found.append(path)
            }
        }
        return found.sorted()
    }

    // MARK: - Sources the project generates before a build

    /// A source a project generates before its build — from a `gyb` template, beside it
    /// under the template's name less `.gyb` — that is not there, with the scheme
    /// pre-actions that would generate it.
    public struct UngeneratedSource: Equatable {
        /// The template, relative to the project's folder.
        public let template: String
        /// What it generates, relative to the project's folder.
        public let output: String
        /// The build pre-actions of the shared schemes that run gyb, in their script or in
        /// a script file of the project's their script names. Empty when none does.
        public let generatedBy: [SchemePreAction]
    }

    /// Every `gyb` template in the application's synchronized folders and in the local
    /// packages whose output is missing, sorted by template. A pre-action generating it
    /// is outside a hermetic build — Semel runs no script whose output depends on the
    /// developer's machine, and NetNewsWire's reads its secrets from the environment and
    /// salts them with fresh random bytes — so it is named for the developer to run, or
    /// the file written by hand, rather than run.
    public static func ungeneratedSources(ofProjectAt project: URL, sdk: String, application name: String? = nil) throws -> [UngeneratedSource] {
        let data = try Data(contentsOf: project.appendingPathComponent("project.pbxproj"))
        let read = try XcodeProject(pbxproj: data)
        let folder = project.deletingLastPathComponent()
        var roots = try localPackagePaths(ofProjectAt: project)
        if let application = try application(of: read, in: folder, sdk: sdk, named: name) {
            roots += read.bundleTargets(of: application).flatMap(\.synchronizedFolders).map(\.path)
        }
        var templates = Set<String>()
        for root in Set(roots).sorted() {
            for file in files(under: folder.appendingPathComponent(root, isDirectory: true)) where file.hasSuffix(".gyb") {
                let template = Path("\(root)/\(file)").resolvingDotSegments?.string ?? "\(root)/\(file)"
                templates.insert(template)
            }
        }
        let missing = templates.sorted().filter { template in
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent(String(template.dropLast(".gyb".count))).path)
        }
        guard !missing.isEmpty else {
            return []
        }
        let generating = XcodeScheme.sharedSchemes(ofProjectAt: project).flatMap(\.buildPreActions).filter {
            runsGyb($0.script, projectFolder: folder)
        }
        return missing.map { UngeneratedSource(template: $0, output: String($0.dropLast(".gyb".count)), generatedBy: generating) }
    }

    /// Whether a pre-action's script runs gyb: says so itself, or names a file inside the
    /// project's folder — `"${PROJECT_DIR}/buildscripts/updateSecrets.sh"` — that does.
    static func runsGyb(_ script: String, projectFolder: URL) -> Bool {
        if script.contains("gyb") {
            return true
        }
        var expanded = script
        for variable in ["${PROJECT_DIR}", "$(PROJECT_DIR)", "$PROJECT_DIR", "${SRCROOT}", "$(SRCROOT)", "$SRCROOT"] {
            expanded = expanded.replacingOccurrences(of: variable, with: projectFolder.path)
        }
        let words = expanded.components(separatedBy: CharacterSet(charactersIn: " \t\n\"'"))
        return words.contains { word in
            guard word.hasPrefix(projectFolder.path + "/"),
                  let text = try? String(contentsOfFile: word, encoding: .utf8) else {
                return false
            }
            return text.contains("gyb")
        }
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
