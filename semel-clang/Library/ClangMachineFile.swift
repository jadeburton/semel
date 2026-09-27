//
//  ClangMachineFile.swift
//  SemelClangTool
//
//  What `semel-clang` does: writes `semel.machine.config` for the clang tools into a folder,
//  outside Semel (B-119), the way `semel-swift prepare` writes it for a Swift tree. The
//  namespaces are the ones SemelClang registers as its own to write, so the list lives with
//  the toolchain and not here.
//
//  Written only when the folder has no machine file: `semel-swift prepare` writes the
//  `clang.*` namespaces too, for a tree with a C-family target, and a file it wrote holds
//  the Swift ones beside them, which this tool would drop. `force` rewrites it anyway — for a
//  file left behind by a toolchain since updated.

import Foundation
import SemelClang
import SemelMachineFile
import SemelNodeKit

public enum ClangMachineFile {

    public enum Outcome: Equatable {
        /// Written, with the namespaces it holds and the tools found on no path here, whose
        /// blocks are comments.
        case written(URL, namespaces: [String], notInstalled: [String])
        /// A machine file was already there and was left as it is.
        case kept(URL)
    }

    /// The namespaces `semel-clang` writes: every one SemelClang registers under its command.
    public static func namespaces() throws -> [ToolNamespace] {
        try SemelClang.register()
        return ToolNamespaceRegistry.all.filter { $0.machineFileCommand == SemelClang.machineFileCommand }
    }

    /// Writes the machine file into `folder` unless one is there, or `force` says to.
    /// `descriptors` is the machine's tools; a test hands in its own.
    public static func write(into folder: URL, platform: Platform, force: Bool,
                             descriptors: () throws -> [ToolDescriptor] = MachineFile.installedDescriptors) throws -> Outcome {
        let file = folder.appendingPathComponent(MachineFile.fileName)
        if !force, FileManager.default.fileExists(atPath: file.path) {
            return .kept(file)
        }
        let namespaces = try namespaces()
        let installed  = try descriptors()
        let text = MachineFile.text(writtenBy: "semel-clang", platform: platform,
                                    descriptors: installed, namespaces: namespaces)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let found = Set(installed.map(\.name))
        let notInstalled = Set(namespaces.map(\.toolName)).subtracting(found).sorted()
        return .written(file, namespaces: namespaces.map(\.namespace), notInstalled: notInstalled)
    }
}
