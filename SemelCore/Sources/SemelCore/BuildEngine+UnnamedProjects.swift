//
//  BuildEngine+UnnamedProjects.swift
//  SemelCore
//
//  A pushed project file that no formula names builds nothing, and nothing else in a
//  settle says so (B-10). This is the idle-time notice that does.
//

import Foundation
import SemelNodeKit

extension BuildEngine {

    /// Says, once per file, which project files a plugin recognises that no formula names:
    /// `input:/Packages/Foo/Package.swift is not named by any formula; a formula's include
    /// SwiftFormulaConverter(path: <Foo>).formula builds it`.
    ///
    /// Named means read: a file some node reads is one a formula reaches, directly or
    /// through the converter of a package that depends on it, because a node exists only
    /// while something is wired below it and the chain ends at a formula's builder. So the
    /// question is one wire query per candidate, and the candidates are what `ProjectFinder`
    /// publishes rather than a walk of every listing.
    ///
    /// Said only after a settle with no errors. While anything fails, a manifest may be
    /// unread because the converter that would read it has not got that far — a package
    /// whose own manifest does not parse reaches none of its dependencies — and a failing
    /// build is not the silent one this is for. A settle with errors leaves the record of
    /// what was said alone, so the notice is neither lost nor repeated across it.
    func reportUnnamedProjects(settleHasErrors: Bool) {
        guard !settleHasErrors,
              let candidates = FatalErrors.attempt({ try includableProjects() }) else {
            return
        }

        var unnamed: [IncludableProject] = []
        for candidate in candidates {
            // A report is best effort: a file the database cannot answer for is passed over.
            guard let isRead = FatalErrors.attempt({ try isReadByAnyNode(inputPath: candidate.path) }), !isRead else {
                continue
            }
            unnamed.append(candidate)
        }

        let paths = Set(unnamed.map(\.path))
        defer { lastReportedUnnamedProjects = paths }

        for candidate in unnamed where !lastReportedUnnamedProjects.contains(candidate.path) {
            let include = Self.formulaText(of: candidate.include, relativeTo: candidate.formulaFolder)
            noticeReporter("⚠️  \(candidate.path) is not named by any formula; "
                         + "a formula's include \(include) builds it")
        }
    }

    /// What `ProjectFinder` last published: empty before it has run.
    private func includableProjects() throws -> [IncludableProject] {
        let finderID = try projectFinder.requireID()
        guard let port = try database.outputPort.select(nodeID: finderID,
                                                        nameSymbolID: ProjectFinder.includableProjectsOutputPort.asSymbolID()),
              port.valueKind == .value,
              let hash = port.dataObjectHash else {
            return []
        }
        return try JSONDecoder().decode([IncludableProject].self, from: Data(try hash.resolveAsString().utf8))
    }

    /// Whether any wire leaves the node for `inputPath`; false when there is no such node.
    private func isReadByAnyNode(inputPath: String) throws -> Bool {
        guard let relative = Path(inputPath).relative(to: Path(Folder.inputFileSystemName)),
              let node = try inputFileSystem.childNode(path: relative) else {
            return false
        }
        return !(try database.wire.select(comingFromNodeID: try node.requireID())).isEmpty
    }

    /// `spec` as a formula would write it from `folder`: a path in the input file system
    /// as `<…>` relative to the folder, anything else quoted. Its properties only: a node a
    /// formula includes by path wires itself from them, as the converter does.
    static func formulaText(of spec: GraphSpecNode, relativeTo folder: String) -> String {
        let arguments = spec.properties.sorted { $0.key < $1.key }.map { property in
            "\(property.key): \(formulaLiteral(property.value, relativeTo: Path(folder)))"
        }
        let port = spec.outputPort.map { ".\($0)" } ?? ""
        return "\(spec.typeName)(\(arguments.joined(separator: ", ")))\(port)"
    }

    private static func formulaLiteral(_ value: String, relativeTo folder: Path) -> String {
        let target = Path(value)
        guard target.firstComponent == Folder.inputFileSystemName,
              folder.firstComponent == Folder.inputFileSystemName else {
            return "'\(value)'"
        }
        let shared = zip(target.segments, folder.segments).prefix { $0 == $1 }.count
        let upward = Array(repeating: "..", count: folder.count - shared)
        let relative = (upward + target.segments.dropFirst(shared)).joined(separator: "/")
        return "<\(relative.isEmpty ? "." : relative)>"
    }
}
