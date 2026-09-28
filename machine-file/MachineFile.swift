//
//  MachineFile.swift
//  SemelMachineFile
//
//  The machine's half of a configuration (B-109), `semel.machine.config`: the descriptors
//  of the tools installed here and the machine settings each namespace declares — the SDK's
//  path or identity — for a platform. Written outside Semel by a toolchain's own tool
//  (B-119): `semel-swift prepare` for a Swift tree, `semel-clang` for a C one. One writer
//  for both, so the file reads the same whichever tool wrote it. It knows no toolchain: the
//  caller registers the toolchains it serves, and hands in the namespaces to write.
//
//  Two tools can write one file — a formula that includes both the `clang` and the `swift`
//  preludes reads both toolchains' namespaces out of it — so each writes its own part and
//  keeps the other's: the file is one section per writer, each under a header naming the
//  writer and the platform, and a writer replaces its own section, takes the namespaces it
//  writes out of the others', and leaves the rest as it found them.

import SemelNodeKit
import SemelProtocol

public enum MachineFile {

    public static let fileName = MachineFileWriter.fileName

    /// The tools the registered toolchains find on this machine, as the server finds them
    /// at launch: each declared finder that locates its tool, under the version it
    /// reports.
    public static func installedDescriptors() throws -> [ToolDescriptor] {
        let registry = ToolRunnerRegistry()
        try ToolDiscovery.registerInstalledTools(into: registry)
        return registry.registeredDescriptors
    }

    // MARK: - One writer's part

    /// One writer's part of the file: its header, then one block per namespace.
    public struct Section: Equatable {
        /// Who wrote it, as its header names it; nil for lines above any header, which no
        /// writer wrote and every writer keeps.
        public let writer: String?
        public let header: [String]
        public var blocks: [Block]

        /// The namespaces its blocks hold, in the order they appear.
        public var namespaces: [String] { blocks.compactMap(\.namespace) }
    }

    /// One namespace's lines: its tool descriptor and machine settings, or the comment
    /// saying its tool is not installed. A line the reader cannot place — a comment someone
    /// added — is a block of its own with no namespace, kept where it was.
    public struct Block: Equatable {
        public let namespace: String?
        public let lines: [String]
    }

    /// A writer's section: for each namespace, alphabetically, the descriptors of its tool
    /// and its machine settings for `platform`. A tool installed in several versions is
    /// pinned to the newest, and a tool not installed leaves a comment saying so — both the
    /// renderer's to decide.
    public static func section(writtenBy writer: String, platform: Platform,
                               descriptors: [ToolDescriptor], namespaces: [ToolNamespace]) -> Section {
        let records = namespaces
            .sorted { $0.namespace < $1.namespace }
            .map { entry -> ToolNamespaceRecord in
                let machineSettings = entry.machineSettings(platform)
                let matching = descriptors
                    .filter { $0.name == entry.toolName }
                    .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }
                    .map { descriptor in
                        ToolDescriptorRecord(name:            descriptor.name,
                                             version:         descriptor.version,
                                             platform:        descriptor.platform,
                                             architecture:    descriptor.architecture,
                                             machineSettings: machineSettings)
                    }
                return ToolNamespaceRecord(namespace: entry.namespace, toolName: entry.toolName,
                                           descriptors: matching, selected: true)
            }
        let blocks = ToolNamespaceRenderer.pinnedToNewest(records).map { record in
            Block(namespace: record.namespace,
                  lines:     ToolNamespaceRenderer.text(for: [record]).components(separatedBy: "\n"))
        }
        return Section(writer: writer,
                       header: ToolNamespaceRenderer.machineFileHeader(writtenBy: writer, platformName: platform.rawValue),
                       blocks: blocks)
    }

    /// The file one writer writes when it is the only one: its section alone.
    public static func text(writtenBy writer: String, platform: Platform,
                            descriptors: [ToolDescriptor], namespaces: [ToolNamespace]) -> String {
        text(of: [section(writtenBy: writer, platform: platform, descriptors: descriptors, namespaces: namespaces)])
    }

    // MARK: - Two writers, one file

    /// What another writer put in the file and a merge kept: its namespaces, by writer.
    public struct Kept: Equatable {
        /// Nil for lines no writer's header claims.
        public let writer: String?
        public let namespaces: [String]

        public init(writer: String?, namespaces: [String]) {
            self.writer     = writer
            self.namespaces = namespaces
        }
    }

    /// What laying a section into a file that was there did to it.
    public struct Merge: Equatable {
        /// The namespaces written that the file held before, rewritten rather than added.
        public let rewritten: [String]
        /// What other writers put there, kept.
        public let kept: [Kept]

        public init(rewritten: [String], kept: [Kept]) {
            self.rewritten = rewritten
            self.kept      = kept
        }
    }

    /// `section` laid into a file that may already be there (B-109), and what that did to
    /// the file — nil when there was none. The writer's own section is replaced whole — a
    /// namespace it no longer writes goes with it — the namespaces it writes are taken out
    /// of every other section, so each namespace is written once, and everything else stays
    /// as it was, in its place. A section left with nothing in it goes; lines no header
    /// claims stay at the top.
    public static func merging(_ section: Section, into existing: String?) -> (text: String, merge: Merge?) {
        guard let existing else {
            return (text(of: [section]), nil)
        }
        let before = Set(sections(in: existing).flatMap(\.namespaces))
        let (text, kept) = replacing(section, in: existing)
        return (text, Merge(rewritten: section.namespaces.filter(before.contains).sorted(), kept: kept))
    }

    /// What a writer says it did: `Wrote <file>: <namespaces>` for a file it made, and for
    /// one that was there, which namespaces it added and which it rewrote, and what of
    /// another writer's it kept — `Added clang.compiler, clang.linker to <file>; kept
    /// swift.compiler, swift.linker from semel-swift prepare`.
    public static func summary(writing namespaces: [String], into file: String, merge: Merge?) -> String {
        let written = namespaces.sorted()
        guard let merge else {
            return "Wrote \(file): \(written.joined(separator: ", "))"
        }
        let added = written.filter { !merge.rewritten.contains($0) }
        var did: [String] = []
        if !added.isEmpty {
            did.append("added \(added.joined(separator: ", "))")
        }
        if !merge.rewritten.isEmpty {
            did.append("rewrote \(merge.rewritten.joined(separator: ", "))")
        }
        let preposition = merge.rewritten.isEmpty ? "to" : "in"
        let action = did.joined(separator: " and ")
        let capitalized = action.prefix(1).uppercased() + String(action.dropFirst())
        var sentence = "\(capitalized) \(preposition) \(file)"
        for kept in merge.kept {
            let writer = kept.writer.map { " from \($0)" } ?? ""
            sentence += "; kept \(kept.namespaces.joined(separator: ", "))\(writer)"
        }
        return sentence
    }

    private static func replacing(_ section: Section, in existing: String) -> (text: String, kept: [Kept]) {
        let writing = Set(section.namespaces)
        var merged: [Section] = []
        var placed = false

        for var other in sections(in: existing) {
            guard other.writer != section.writer else {
                if !placed {
                    merged.append(section)
                    placed = true
                }
                continue
            }
            other.blocks.removeAll { $0.namespace.map(writing.contains) ?? false }
            if !other.blocks.isEmpty {
                merged.append(other)
            }
        }
        if !placed {
            merged.append(section)
        }

        let kept = merged
            .filter { $0.writer != section.writer && !$0.namespaces.isEmpty }
            .map { Kept(writer: $0.writer, namespaces: $0.namespaces) }
        return (text(of: merged), kept)
    }

    /// The sections of a machine file's text, in order: each starting at a writer's
    /// header, and the lines above the first header as a section no writer wrote. The
    /// file is generated, so this reads what `text(of:)` writes — a header, a blank line,
    /// then blocks — and a line whose key it can read is placed under that key's namespace.
    public static func sections(in text: String) -> [Section] {
        var sections: [Section] = []
        var writer: String?
        var header: [String] = []
        var readingHeader = false
        var blocks: [Block] = []
        var blockIsOpen = false

        func close() {
            if writer != nil || !blocks.isEmpty {
                sections.append(Section(writer: writer, header: header, blocks: blocks))
            }
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix(ToolNamespaceRenderer.machineFileHeaderOpening) {
                close()
                writer        = writerNamed(inHeaderLine: line)
                header        = [line]
                readingHeader = true
                blocks        = []
                blockIsOpen   = false
                continue
            }
            if readingHeader, line.hasPrefix("//"), namespaceOf(line: line) == nil {
                header.append(line)
                continue
            }
            readingHeader = false
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                blockIsOpen = false
                continue
            }
            // A block runs to a blank line or to a line of another namespace.
            let namespace = namespaceOf(line: line)
            if blockIsOpen, let last = blocks.last, last.namespace == namespace {
                blocks[blocks.count - 1] = Block(namespace: namespace, lines: last.lines + [line])
            } else {
                blocks.append(Block(namespace: namespace, lines: [line]))
            }
            blockIsOpen = true
        }
        close()
        return sections
    }

    /// The file's text: each section's header, a blank line, then its blocks a blank line
    /// apart; sections a blank line apart; a newline at the end.
    public static func text(of sections: [Section]) -> String {
        let parts = sections.map { section -> String in
            var paragraphs = section.header.isEmpty ? [] : [section.header.joined(separator: "\n")]
            paragraphs += section.blocks.map { $0.lines.joined(separator: "\n") }
            return paragraphs.joined(separator: "\n\n")
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// `semel-clang` out of `// Written by semel-clang for --platform macos: …`.
    private static func writerNamed(inHeaderLine line: String) -> String {
        let rest = line.dropFirst(ToolNamespaceRenderer.machineFileHeaderOpening.count)
        if let end = rest.range(of: " for --platform ") ?? rest.range(of: ":") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }

    /// The namespace a line of the file belongs to: `clang.linker` for
    /// `clang.linker.sdkPath=…` and for `// clang.linker: no clang is installed…`. A
    /// namespace is a domain and a node, two segments, however many the key has after it.
    private static func namespaceOf(line: String) -> String? {
        if line.hasPrefix("// ") {
            let comment = line.dropFirst(3)
            guard let colon = comment.firstIndex(of: ":") else {
                return nil
            }
            let named = String(comment[..<colon])
            return named.contains(" ") ? nil : named
        }
        guard let equals = line.firstIndex(of: "=") else {
            return nil
        }
        let segments = line[..<equals].split(separator: ".")
        guard segments.count > 2 else {
            return nil
        }
        return segments.prefix(2).joined(separator: ".")
    }
}
