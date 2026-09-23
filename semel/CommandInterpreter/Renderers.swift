// Renderers.swift
// semel
//
// How structured replies become text. These are the client's twins of renderers the
// engine keeps for its own terminal: `ErrorRecordRenderer` matches `ErrorReport.lines`
// line for line, and both sides' tests pin the format so they cannot drift apart.

import Foundation
import SemelProtocol

/// The marks the prompt is allowed to use, all of them, in one place.
///
/// A mark per event type would end as a mark per command, and a screen with one of
/// everything on it says nothing. Three earn their place: a failure, a settle that had
/// none, and a settle the cache answered part of — the distinction Semel exists to make
/// and the one a user cannot otherwise see. Anything else prints unmarked until there is
/// a reason it cannot.
enum Mark {
    /// A node that failed. `ErrorRecordRenderer` opens every record with it.
    static let failure = "❌"

    /// A settle that produced no errors and did all of its work.
    static let settled = "✅"

    /// A settle that produced no errors and skipped some of the work, because the cache
    /// had the answer.
    static let fromCache = "⚡️"
}

enum SettleSummaryRenderer {

    /// One line for one settle, or nothing when the settle had nothing to do.
    ///
    /// The counts are the engine's, passed through: `scheduled` is what was woken, and it
    /// exceeds `computed + fromCache` by however many nodes were woken before their
    /// inputs were ready. The mark is the only reading the client adds.
    static func line(scheduled: Int, computed: Int, fromCache: Int, errors: Int) -> String? {
        guard scheduled > 0 else {
            return nil
        }

        // A settle where nothing ran at all is the rare case, even when almost nothing
        // did: a rebuilt manifest or a reread include list recomputes beside twenty cache
        // hits. The mark therefore says whether the cache answered any of it, which is
        // the question, rather than whether it answered all of it, which is nearly never.
        let mark: String = {
            if errors > 0 {
                return Mark.failure
            }
            return fromCache > 0 ? Mark.fromCache : Mark.settled
        }()

        let nodes  = scheduled == 1 ? "node"  : "nodes"
        let errorWord = errors == 1 ? "error" : "errors"

        return "\(mark) \(scheduled) \(nodes) scheduled, \(computed) computed, "
             + "\(fromCache) from cache, \(errors) \(errorWord)"
    }
}

enum ErrorRecordRenderer {

    /// A heading, then one line per distinct message naming the ports that carry it, or
    /// an indented block when a message spans lines. Ends with a blank line.
    static func lines(for record: ErrorRecord) -> [String] {
        var result = ["\(Mark.failure) \(record.label)"]

        for entry in record.entries {
            let portNames = entry.ports.joined(separator: ", ")

            let body = entry.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !body.isEmpty else {
                result.append("   · \(portNames): (no details)")
                continue
            }

            if body.count == 1 {
                result.append("   · \(portNames): \(body[0])")
            } else {
                result.append("   · \(portNames):")
                result.append(contentsOf: body.map { "     \($0)" })
            }
        }

        // The cascade under the failure, as a count rather than a line per node carrying it.
        switch record.downstreamCarrierCount {
        case ..<1: break
        case 1:    result.append("   · and 1 node downstream carries it")
        default:   result.append("   · and \(record.downstreamCarrierCount) nodes downstream carry it")
        }

        result.append("")
        return result
    }
}

enum ToolNamespaceRenderer {

    /// The installed tools as the settings a `semel.config` needs — one block per
    /// namespace that names the tool, so choosing a toolchain version is a paste. A
    /// namespace whose tool is missing prints as a comment, so the whole output is safe
    /// to paste and still says what is absent.
    static func text(for namespaces: [ToolNamespaceRecord]) -> String {
        var blocks: [String] = []

        for namespace in namespaces {
            guard !namespace.descriptors.isEmpty else {
                blocks.append("// \(namespace.namespace): no \(namespace.toolName) is installed on this machine")
                continue
            }

            for descriptor in namespace.descriptors {
                var lines = [
                    "\(namespace.namespace).toolDescriptor.name=\(descriptor.name)",
                    "\(namespace.namespace).toolDescriptor.version=\(descriptor.version)",
                    "\(namespace.namespace).toolDescriptor.platform=\(descriptor.platform)",
                    "\(namespace.namespace).toolDescriptor.architecture=\(descriptor.architecture)",
                ]
                for key in descriptor.machineSettings.keys.sorted() {
                    lines.append("\(namespace.namespace).\(key)=\(descriptor.machineSettings[key]!)")
                }
                blocks.append(lines.joined(separator: "\n"))
            }
        }

        return blocks.joined(separator: "\n\n")
    }
}
