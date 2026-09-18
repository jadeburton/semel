//
//  XcodeProjectConverter.swift
//  SemelApple
//
//  Turns an Xcode project into formula text, the way `SwiftFormulaConverter` turns a
//  package manifest into one: a formula names the project —
//  `include XcodeProjectConverter(path: <IceCubesApp.xcodeproj>, root: <.>).formula` —
//  and the node wires what it needs itself: the project file, the xcconfig files it
//  names, and the manifests of the folders that are the targets' sources, walked to
//  every subfolder so the resources in them are known. No tool runs; the project file is
//  a property list. `XcodeProject` reads it, `XcodeBuildSettings` evaluates it, and
//  `XcodeFormulaEmitter` writes the formula; this node owns the wires and the waiting.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

public struct XcodeProjectConverter: Node {
    public static let kind: UInt = 34

    // MARK: Ports

    /// `project.pbxproj`, one wire.
    static let projectFile = "projectFile"
    /// The `.xcconfig` files the project and the target name, keyed by path. One the
    /// clone does not have arrives without a value, and is then an empty layer.
    static let xcconfigs = "xcconfigs"
    /// The targets' synchronized folders and every folder under them, keyed by path.
    static let folders = "folders"
    static let formulaOutput = "formula"
    static let infoLog = "infoLog"

    /// The config namespaces the formula this converter emits selects from, for the
    /// targets it writes itself. The package formulas it includes select from
    /// `SwiftFormulaConverter`'s; `prepare` writes a block for each of both and no other,
    /// because a block nothing reads is reported as unused keys on every build.
    public static let configNamespaces: [String] = [
        XcodeFormulaEmitter.swiftCompilerNamespace,
        XcodeFormulaEmitter.swiftLinkerNamespace,
        AssetCatalogCompilerConfiguration.settingNamespace,
        StringCatalogCompilerConfiguration.settingNamespace,
    ]

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    /// Every port is dynamic: the node wires them from `path` itself, and a required port
    /// would have to be wired before the node exists.
    public static let descriptor = NodeDescriptor(
        inputPorts: [.dynamic(projectFile), .dynamic(xcconfigs), .dynamic(folders)],
        outputPorts: [formulaOutput, infoLog]
    )

    // MARK: Properties

    /// `input:/repo/IceCubesApp.xcodeproj`.
    var projectPath: String {
        get throws {
            guard let path = thisNode.properties["path"] else {
                throw NodeError.other(message: "XcodeProjectConverter needs a project: give it path: <X.xcodeproj>")
            }
            return path
        }
    }

    /// The folder holding the project, which its paths are relative to.
    var projectFolder: String {
        get throws { (Path(try projectPath).deletingLastComponent ?? Path("")).string }
    }

    /// Where `semel.config` and `Dependencies/` live: `root` when the formula gives one,
    /// else the project's folder.
    var buildRoot: String {
        get throws {
            if let root = thisNode.properties["root"] {
                return root
            }
            return try projectFolder
        }
    }

    var configurationName: String { thisNode.properties["configuration"] ?? "Debug" }
    var sdk: String { thisNode.properties["sdk"] ?? "iphonesimulator" }

    // MARK: Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let projectFilePath = "\(try projectPath)/project.pbxproj"
        var specs: [String: [String: String]] = [
            Self.projectFile: [projectFilePath: "StaticFile(path: '\(projectFilePath)').output"],
            Self.xcconfigs: [:],
            Self.folders: [:],
        ]

        // ── the project file, a pass later than the node's creation ─────────
        guard let projectValue = input.inputValues[Self.projectFile]?[projectFilePath] else {
            return pending("waiting for \(projectFilePath)", specs: specs)
        }
        let projectHash: DataObjectHash
        switch projectValue {
        case .noValue(.pending):
            return pending("waiting for \(projectFilePath)", specs: specs)
        case .noValue(.error):
            return failed("\(projectFilePath) is not in the input file system; push the project's folder", specs: specs)
        case .value(let hash):
            projectHash = hash
        }
        guard let projectBytes = try DataObjectStore.shared.read(hash: projectHash) else {
            return failed("\(projectFilePath) has no content", specs: specs)
        }
        let project = try XcodeProject(pbxproj: Data(projectBytes))
        guard let application = project.targets.first(where: \.isApplication) else {
            return failed("the project has no application target", specs: specs)
        }

        // ── the xcconfig files the project and the target name ──────────────
        let projectFolder = try projectFolder
        let xcconfigPaths = project.xcconfigPaths(for: application, configuration: configurationName)
            .map { "\(projectFolder)/\($0)" }
        for path in xcconfigPaths {
            specs[Self.xcconfigs]?[path] = "StaticFile(path: '\(path)').output"
        }
        // ── the target's folders, walked ─────────────────────────────────────
        // Demanded alongside the xcconfig files, so the two waits overlap.
        let manifests = FolderTreeWalk.manifests(in: input, port: Self.folders)
        let arrived = Dictionary(uniqueKeysWithValues: manifests.map { ($0.key, $0.manifest) })
        // The application's folders and every embedded extension's: each is a bundle
        // whose resources come from its own folder.
        let embedded = application.embeddedExtensions.compactMap { name in
            project.targets.first { $0.productFileName == name && $0.isExtension }
        }
        let sourceFolders = ([application] + embedded).flatMap(\.synchronizedFolders).map { "\(projectFolder)/\($0.path)" }
        var demanded: [String] = sourceFolders
        var index = 0
        while index < demanded.count {
            let folder = demanded[index]
            index += 1
            specs[Self.folders]?[folder] = "Folder(path: '\(folder)').manifest"
            guard let manifest = arrived[folder] else {
                continue
            }
            // A catalog is compiled whole by its own node, which walks it itself.
            for entry in manifest.entries where entry.isFolder && entry.isPinned && !Self.isCompiledWhole(entry.name) {
                demanded.append("\(folder)/\(entry.name)")
            }
        }

        let xcconfigValues = input.inputValues[Self.xcconfigs] ?? [:]
        guard xcconfigPaths.allSatisfy({ xcconfigValues[$0] != nil }) else {
            return pending("waiting for the xcconfig files", specs: specs)
        }
        var xcconfigTexts: [String: String] = [:]
        for (path, value) in xcconfigValues {
            if case .value(let hash) = value, let text = try? hash.resolveAsString() {
                xcconfigTexts[path] = text
            }
        }
        guard demanded.allSatisfy({ arrived[$0] != nil }) else {
            return pending("walking the target's folders", specs: specs)
        }

        var listings: [String: XcodeFormulaEmitter.FolderListing] = [:]
        for sourceFolder in sourceFolders {
            var listing = XcodeFormulaEmitter.FolderListing()
            for folder in demanded where folder == sourceFolder || folder.hasPrefix(sourceFolder + "/") {
                guard let manifest = arrived[folder] else { continue }
                let prefix = folder == sourceFolder ? "" : String(folder.dropFirst(sourceFolder.count + 1)) + "/"
                for entry in manifest.entries where entry.isPinned {
                    if entry.isFolder {
                        listing.folders.append(prefix + entry.name)
                    } else {
                        listing.files.append(prefix + entry.name)
                    }
                }
            }
            listings[sourceFolder] = listing
        }

        // ── the formula ──────────────────────────────────────────────────────
        let build = XcodeFormulaEmitter.Build(root: try buildRoot, projectFolder: projectFolder,
                                              configuration: configurationName, sdk: sdk)
        let emitter = XcodeFormulaEmitter(project: project, build: build)
        let formula = try emitter.formula(
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: self.configurationName, sdk: self.sdk,
                                               xcconfig: { xcconfigTexts["\(projectFolder)/\($0)"] },
                                               extra: ["TARGET_NAME": target.name])
            },
            listing: { listings[$0] })

        return .init(outputValues: [Self.formulaOutput: .value(try formula.intern()),
                                    Self.infoLog: try infoLogValue(application: application, embedded: embedded, project: project,
                                                                   projectFolder: projectFolder, xcconfigPaths: xcconfigPaths,
                                                                   xcconfigTexts: xcconfigTexts)],
                     inputWireSpecs: specs)
    }

    /// The success message, or — once an xcconfig the project names has no value — the
    /// cause, as an error: which file is missing and which settings it would have defined.
    /// An error here, not just the info it replaces, is what lets this reach the idle error
    /// report; `formulaOutput` still carries the formula, since one port's error does not
    /// stop another port on the same node from carrying its value. The settings are
    /// resolved again over the application and its extensions — the same evaluation
    /// `XcodeFormulaEmitter` already ran per target — so the message names exactly what the
    /// missing file would have to define.
    private func infoLogValue(application: XcodeProject.Target, embedded: [XcodeProject.Target], project: XcodeProject,
                              projectFolder: String, xcconfigPaths: [String], xcconfigTexts: [String: String]) throws -> NodeValue {
        let missing = xcconfigPaths.filter { xcconfigTexts[$0] == nil }
        guard !missing.isEmpty else {
            return .value(try "converted \(application.name) for \(sdk), \(configurationName)".intern())
        }

        var undefinedNames = Set<String>()
        for target in [application] + embedded {
            let settings = try XcodeBuildSettings.resolve(project: project, target: target, configuration: configurationName, sdk: sdk,
                                                           xcconfig: { xcconfigTexts["\(projectFolder)/\($0)"] },
                                                           extra: ["TARGET_NAME": target.name])
            undefinedNames.formUnion(settings.unresolvedReferences)
        }
        let names = undefinedNames.sorted().joined(separator: ", ")
        let message = missing
            .map { "xcconfig \($0) is missing; settings it would define are undefined (\(names))" }
            .joined(separator: "\n")
        return .noValue(reason: .error(messageDataObjectHash: try message.intern()))
    }

    /// Folders whose contents are one compiled unit: never walked, so their files are not
    /// mistaken for resources of their own.
    static func isCompiledWhole(_ folderName: String) -> Bool {
        folderName.hasSuffix(".xcassets") || folderName.hasSuffix(".icon") || folderName.hasSuffix(".lproj")
            || folderName.hasSuffix(".xcdatamodeld")
    }

    private func pending(_ reason: String, specs: [String: [String: String]]) -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .pending),
                             Self.infoLog: .noValue(reason: .pending)],
              inputWireSpecs: specs)
    }

    private func failed(_ message: String, specs: [String: [String: String]]) -> ProcessOutput {
        let reason = NoValueReason.error(messageDataObjectHash: (try? "XcodeProjectConverter: \(message)".intern()) ?? "")
        return .init(outputValues: [Self.formulaOutput: .noValue(reason: reason),
                                    Self.infoLog: .noValue(reason: reason)],
                     inputWireSpecs: specs)
    }
}
