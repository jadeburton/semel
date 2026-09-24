// Renderers.swift
// semel
//
// How structured replies become text. These are the client's twins of renderers the
// engine keeps for its own terminal: `ErrorRecordRenderer` matches `ErrorReport.lines`
// line for line, and both sides' tests pin the format so they cannot drift apart.

import Foundation
import SemelProtocol

enum ErrorRecordRenderer {

    /// A heading, then one line per distinct message naming the ports that carry it, or
    /// an indented block when a message spans lines. Ends with a blank line.
    static func lines(for record: ErrorRecord) -> [String] {
        var result = ["❌ \(record.label)"]

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
