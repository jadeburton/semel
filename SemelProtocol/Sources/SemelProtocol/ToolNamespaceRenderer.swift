// ToolNamespaceRenderer.swift
// SemelProtocol
//
// The installed tools as config text. In the protocol package rather than the CLI because
// two writers render it (B-109): `semel tools` renders what the daemon answers, and
// `semel-swift prepare` renders the same facts read in-process — one shape, one place,
// and both depend on nothing but the records.

public enum ToolNamespaceRenderer {

    /// The installed tools as the settings a config needs — one block per namespace that
    /// names the tool, every installed version of it, so choosing a toolchain version is a
    /// paste. A namespace whose tool is missing prints as a comment, so the whole output is
    /// safe to paste and still says what is absent.
    public static func text(for namespaces: [ToolNamespaceRecord]) -> String {
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

    /// Each namespace pinned to the newest installed version of its tool: a listing shows
    /// every version, a machine file has to name one. The descriptors arrive sorted oldest
    /// first, so the newest is the last.
    public static func pinnedToNewest(_ namespaces: [ToolNamespaceRecord]) -> [ToolNamespaceRecord] {
        namespaces.map { namespace in
            ToolNamespaceRecord(namespace:   namespace.namespace,
                                toolName:    namespace.toolName,
                                descriptors: Array(namespace.descriptors.suffix(1)),
                                selected:    namespace.selected)
        }
    }

    /// The lines that open one writer's part of a machine file: who wrote it, for which
    /// platform, and that nobody edits or commits it. A file two writers wrote has two, one
    /// above each writer's namespaces (B-109), so each part says whose it is and what
    /// writes it again.
    public static func machineFileHeader(writtenBy writer: String, platformName: String) -> [String] {
        [
            "\(machineFileHeaderOpening)\(writer) for --platform \(platformName): the tools and SDK this",
            "// machine has. Not for editing — write it again after installing a toolchain —",
            "// and not for checking in: the project's own choices go in semel.config beside it.",
        ]
    }

    /// How a header's first line starts, which is how a writer reading the file back finds
    /// where each writer's part begins.
    public static let machineFileHeaderOpening = "// Written by "
}
