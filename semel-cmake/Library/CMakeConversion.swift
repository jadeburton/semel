//
//  CMakeConversion.swift
//  SemelCMakeTool
//
//  What `semel-cmake` does: reads a folder's `CMakeLists.txt` and the files it reaches,
//  evaluates the declarative subset into a model, and writes the formula and the
//  project's config beside it, once — a file already there is the person's now, and is
//  never overwritten — then writes the clang part of the machine file the formula reads,
//  as `semel-clang` would. The disk is touched here and nowhere in SemelCMake: the three
//  stages take a reader and give back text, which is what lets them run under a node
//  later.
//

import Foundation
import SemelCMake
import SemelClangTool
import SemelMachineFile
import SemelNodeKit

public struct CMakeConversionReport: Equatable {
    public struct Target: Equatable {
        public var name: String
        public var kind: String
        /// The product the formula names, nil for a target that builds nothing.
        public var product: String?

        public init(name: String, kind: String, product: String?) {
            self.name    = name
            self.kind    = kind
            self.product = product
        }
    }

    public var projectName: String?
    public var targets: [Target] = []
    /// One line each, as the model describes them.
    public var untranslated: [String] = []
    public var written: [URL] = []
    public var kept: [URL] = []
    /// What the machine-file writer said.
    public var machineFileLines: [String] = []
    public var platform: Platform
    public var target: String

    public init(platform: Platform, target: String) {
        self.platform = platform
        self.target   = target
    }
}

public enum CMakeConversionError: Error, CustomStringConvertible {
    case noCMakeLists(URL)

    public var description: String {
        switch self {
        case .noCMakeLists(let folder):
            return "no CMakeLists.txt in \(folder.path)"
        }
    }
}

public enum CMakeConversion {

    public static let rootFileName = "CMakeLists.txt"

    /// The deployment version the target triple carries when the project states no
    /// `CMAKE_OSX_DEPLOYMENT_TARGET`: what the C fixtures build for.
    public static let defaultDeploymentVersion = "14.0"

    /// Converts the project in `folder`. `descriptors` is the machine's tools for the
    /// machine file; a test hands in its own.
    public static func run(folder: URL, platform: Platform,
                           descriptors: () throws -> [ToolDescriptor] = MachineFile.installedDescriptors) throws -> CMakeConversionReport {
        let folder = folder.standardizedFileURL
        let rootFile = folder.appendingPathComponent(rootFileName)
        guard FileManager.default.fileExists(atPath: rootFile.path) else {
            throw CMakeConversionError.noCMakeLists(folder)
        }
        let rootText = try String(contentsOf: rootFile, encoding: .utf8)
        let root     = try CMakeFile.parse(rootText, path: rootFileName)
        let facts    = CMakeFacts.macOS(sourceDirectory: folder.path)
        let project  = try CMakeEvaluation.evaluate(root: root, facts: facts) { relativePath in
            let file = folder.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: file.path) else {
                return nil
            }
            return try String(contentsOf: file, encoding: .utf8)
        }

        let target  = platform.target(deploymentVersion: project.deploymentTarget ?? defaultDeploymentVersion)
        let build   = CMakeFormulaEmitter.Build(target: target, machineConfigPath: MachineFile.fileName)
        let emitter = CMakeFormulaEmitter(project: project, build: build)
        var report  = CMakeConversionReport(platform: platform, target: target)
        report.projectName  = project.name
        report.untranslated = project.untranslated.map(\.description)
        report.targets      = project.targets.map { target in
            CMakeConversionReport.Target(name: target.name, kind: kindDescription(target.kind),
                                         product: productName(of: target))
        }

        for (name, text) in [(CMakeFormulaEmitter.formulaFileName, emitter.formula()),
                             (CMakeFormulaEmitter.configFileName, emitter.config())] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                report.kept.append(file)
                continue
            }
            try text.write(to: file, atomically: true, encoding: .utf8)
            report.written.append(file)
        }

        // The formula reads the machine file beside it, so that is where it is written.
        report.machineFileLines = try ClangMachineFile.write(into: folder, platform: platform, force: false,
                                                             descriptors: descriptors).lines
        return report
    }

    private static func kindDescription(_ kind: CMakeTarget.Kind) -> String {
        switch kind {
        case .executable:       return "executable"
        case .staticLibrary:    return "static library"
        case .sharedLibrary:    return "shared library"
        case .interfaceLibrary: return "header-only library"
        }
    }

    private static func productName(of target: CMakeTarget) -> String? {
        guard target.kind != .interfaceLibrary,
              target.sources.contains(where: CMakeLanguage.isCompiled) else {
            return nil
        }
        return CMakeFormulaEmitter.productName(of: target)
    }
}
