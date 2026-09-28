//
//  ClangMachineFile.swift
//  SemelClangTool
//
//  What `semel-clang` does: writes the clang tools' part of `semel.machine.config` into a
//  folder, outside Semel (B-119), the way `semel-swift prepare` writes it for a Swift tree.
//  The namespaces are the ones SemelClang registers as its own to write, so the list lives
//  with the toolchain and not here — narrowed to the ones the formulas reading the file
//  select, when there are such formulas, as `prepare` narrows its own.
//
//  A file already there may be another writer's: `prepare` writes the Swift namespaces, and
//  a formula that includes both the `clang` and the `swift` preludes reads both out of one
//  file. So this adds its namespaces to it and keeps the rest (B-109). A file that already
//  holds every namespace this would write is left as it is — the same machine gives the
//  same answer — and `force` rewrites them anyway: for a file left behind by a toolchain
//  since updated.

import Foundation
import SemelClang
import SemelMachineFile
import SemelNodeKit

public enum ClangMachineFile {

    public enum Outcome: Equatable {
        /// Written, with the namespaces this tool wrote, the tools found on no path here,
        /// whose blocks are comments, and the formulas whose selection chose the namespaces
        /// — relative to the folder, and empty when every clang namespace was written. `merge`
        /// is what writing did to a file that was there, nil when there was none.
        case written(URL, namespaces: [String], notInstalled: [String], selectedBy: [String], merge: MachineFile.Merge?)
        /// The file already holds every namespace this tool would write, and was left as
        /// it is.
        case kept(URL, namespaces: [String])

        /// What `semel-clang` prints about it.
        public var lines: [String] {
            switch self {
            case .written(let file, let namespaces, let notInstalled, let selectedBy, let merge):
                var lines = [MachineFile.summary(writing: namespaces, into: file.path, merge: merge)]
                if selectedBy.count == 1 {
                    lines.append("Those \(selectedBy[0]) selects; when it selects others, run semel-clang again.")
                }
                if selectedBy.count > 1 {
                    lines.append("Those \(selectedBy.joined(separator: ", ")) select; when they select others, run semel-clang again.")
                }
                if !notInstalled.isEmpty {
                    lines.append("No \(notInstalled.joined(separator: ", ")) is installed here; those blocks are comments.")
                }
                return lines

            case .kept(let file, let namespaces):
                return ["Kept \(file.path): it holds \(namespaces.joined(separator: ", ")) already; --force rewrites them"]
            }
        }
    }

    /// The namespaces `semel-clang` writes: every one SemelClang registers under its command.
    public static func namespaces() throws -> [ToolNamespace] {
        try SemelClang.register()
        return ToolNamespaceRegistry.all.filter { $0.machineFileWriter == SemelClang.machineFileWriter }
    }

    /// Writes the clang namespaces into the machine file in `folder`, keeping what another
    /// writer put there, unless the file holds them all already and `force` does not say to
    /// write them again. `descriptors` is the machine's tools; a test hands in its own.
    ///
    /// The namespaces are the ones the formulas that read the file select, because a block
    /// no `ConfigFilter` selects is reported as unused keys on every build — the tutorial's
    /// project links nothing through the archiver. With no such formula, or one that selects
    /// no clang namespace this can read — a converter's formula, whose text is computed at
    /// build time — every one is written, since a file that held none would help nobody.
    public static func write(into folder: URL, platform: Platform, force: Bool,
                             descriptors: () throws -> [ToolDescriptor] = MachineFile.installedDescriptors) throws -> Outcome {
        let file     = folder.appendingPathComponent(MachineFile.fileName)
        let existing = FileManager.default.fileExists(atPath: file.path)
            ? try String(contentsOf: file, encoding: .utf8)
            : nil

        let every    = try namespaces()
        let formulas = formulas(reading: file, under: folder)
        let selected = Set(formulas.flatMap { MachineFile.namespaces(selectedIn: $0.text) })
        let chosen   = every.filter { selected.contains($0.namespace) }
        let written  = chosen.isEmpty ? every : chosen
        let names    = written.map(\.namespace).sorted()

        // Left as it is when it holds every namespace the formulas select — in this tool's
        // part or another writer's — and this tool's part holds none they no longer do.
        if !force, let existing {
            let sections = MachineFile.sections(in: existing)
            let present  = Set(sections.flatMap(\.namespaces))
            let own      = sections.filter { $0.writer == SemelClang.machineFileWriter.command }.flatMap(\.namespaces)
            if names.allSatisfy(present.contains), own.allSatisfy(names.contains) {
                return .kept(file, namespaces: names)
            }
        }

        let installed = try descriptors()
        let section = MachineFile.section(writtenBy: SemelClang.machineFileWriter.command, platform: platform,
                                          descriptors: installed, namespaces: written)
        let (text, merge) = MachineFile.merging(section, into: existing)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let found = Set(installed.map(\.name))
        let notInstalled = Set(written.map(\.toolName)).subtracting(found).sorted()
        return .written(file, namespaces: names, notInstalled: notInstalled,
                        selectedBy: chosen.isEmpty ? [] : formulas.map(\.relativePath), merge: merge)
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
