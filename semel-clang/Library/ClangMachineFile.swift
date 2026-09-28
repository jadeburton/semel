//
//  ClangMachineFile.swift
//  SemelClangTool
//
//  What `semel-clang` does: writes `semel.machine.config` for the clang tools into a folder,
//  outside Semel (B-119), the way `semel-swift prepare` writes it for a Swift tree. The
//  namespaces are the ones SemelClang registers as its own to write, so the list lives with
//  the toolchain and not here — narrowed to the ones the formulas reading the file select,
//  when there are such formulas, as `prepare` narrows its own.
//
//  Written only when the folder has no machine file: `semel-swift prepare` writes the
//  `clang.*` namespaces too, for a tree with a C-family target, and a file it wrote holds
//  the Swift ones beside them, which this tool would drop. `force` rewrites it anyway — for a
//  file left behind by a toolchain since updated, or a formula that now selects another.

import Foundation
import SemelClang
import SemelMachineFile
import SemelNodeKit

public enum ClangMachineFile {

    public enum Outcome: Equatable {
        /// Written, with the namespaces it holds, the tools found on no path here, whose
        /// blocks are comments, and the formulas whose selection chose the namespaces —
        /// relative to the folder, and empty when every clang namespace was written.
        case written(URL, namespaces: [String], notInstalled: [String], selectedBy: [String])
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
    ///
    /// The namespaces are the ones the formulas that read the file select, because a block
    /// no `ConfigFilter` selects is reported as unused keys on every build — the tutorial's
    /// project links nothing through the archiver. With no such formula, or one that selects
    /// no clang namespace this can read — a converter's formula, whose text is computed at
    /// build time — every one is written, since a file that held none would help nobody.
    public static func write(into folder: URL, platform: Platform, force: Bool,
                             descriptors: () throws -> [ToolDescriptor] = MachineFile.installedDescriptors) throws -> Outcome {
        let file = folder.appendingPathComponent(MachineFile.fileName)
        if !force, FileManager.default.fileExists(atPath: file.path) {
            return .kept(file)
        }
        let every    = try namespaces()
        let formulas = formulas(reading: file, under: folder)
        let selected = Set(formulas.flatMap { MachineFile.namespaces(selectedIn: $0.text) })
        let chosen   = every.filter { selected.contains($0.namespace) }
        let written  = chosen.isEmpty ? every : chosen

        let installed = try descriptors()
        let text = MachineFile.text(writtenBy: "semel-clang", platform: platform,
                                    descriptors: installed, namespaces: written)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let found = Set(installed.map(\.name))
        let notInstalled = Set(written.map(\.toolName)).subtracting(found).sorted()
        return .written(file, namespaces: written.map(\.namespace).sorted(), notInstalled: notInstalled,
                        selectedBy: chosen.isEmpty ? [] : formulas.map(\.relativePath))
    }

    /// The formulas under `folder` that read `file`: every `.fmla` below it, hidden folders
    /// left out, naming a path that resolves to `file` — the tutorial's `hello/hello.fmla`
    /// says `<../semel.machine.config>`, one level up from itself, which is where this
    /// tool is pointed. In path order.
    static func formulas(reading file: URL, under folder: URL) -> [(relativePath: String, text: String)] {
        let wantedFolder = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let reference    = "<([^<>']*" + NSRegularExpression.escapedPattern(for: MachineFile.fileName) + ")>"
        guard let regex = try? NSRegularExpression(pattern: reference),
              let walk  = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var found: [(relativePath: String, text: String)] = []
        for case let formula as URL in walk where formula.pathExtension == "fmla" {
            guard let text = try? String(contentsOf: formula, encoding: .utf8) else {
                continue
            }
            let formulaFolder = formula.deletingLastPathComponent()
            let readsTheFile = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
                guard let range = Range(match.range(at: 1), in: text) else {
                    return false
                }
                let named = formulaFolder.appendingPathComponent(String(text[range])).standardizedFileURL
                return named.lastPathComponent == MachineFile.fileName
                    && named.deletingLastPathComponent().resolvingSymlinksInPath().path == wantedFolder
            }
            guard readsTheFile else {
                continue
            }
            let formulaPath  = formula.standardizedFileURL.resolvingSymlinksInPath().path
            let relativePath = formulaPath.hasPrefix(wantedFolder + "/")
                ? String(formulaPath.dropFirst(wantedFolder.count + 1))
                : formulaPath
            found.append((relativePath, text))
        }
        return found.sorted { $0.relativePath < $1.relativePath }
    }
}
