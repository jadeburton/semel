// ErrorReport.swift
// SemelCore
//
// How a node's errors are written out, in the one place that decides it.
//
// Two callers want this: the engine, which reports errors as it settles, and the CLI's
// `errors` command, which reports them on request. They differ in *which* errors they show —
// the engine only what is newly appearing, the command everything — and that is a question
// about selection, not about shape. Answering the shape twice gave a failure one form when
// it appeared by itself and another when it was asked for, both under the same ❌.

import SemelDatabaseModels
import SemelNodeKit

/// One node's errors, rendered.
public enum ErrorReport {

    /// One distinct message a node is carrying, and the ports carrying it.
    public struct Item: Equatable {
        public let ports:   [String]
        public let message: String

        public init(ports: [String], message: String) {
            self.ports   = ports
            self.message = message
        }
    }

    /// One node's errors, gathered but not yet rendered. The engine hands these to its
    /// reporter, and a server turns them into wire records; only the terminal turns them
    /// into lines.
    public struct Entry: Equatable {
        public let label: String
        public let items: [Item]

        public init(label: String, items: [Item]) {
            self.label = label
            self.items = items
        }
    }

    /// What to call a node in a report.
    ///
    /// The internal id is a surrogate integer and means nothing to the person reading, so it
    /// is the last resort rather than the first: a path if the node has one, the project file
    /// if it is a builder, the type name otherwise.
    public static func label(forNodeID nodeID: ObjectID, database: DatabaseLayer) -> String {
        // A label for a report is best effort — the report must never fail — but a machine
        // failure on the way to it still reaches the fatal handler.
        guard let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil,
              let node = try? nodeRecord.nodeAsAny() else {
            return "Node \(nodeID)"
        }

        let typeName = String(describing: type(of: node))

        if let path = nodeRecord.properties["path"] {
            return "\(typeName)  '\(path)'"
        }

        if let wires = FatalErrors.attempt({
               try database.wire.select(goingToNodeID: nodeID, toSymbolID: "projectFile".asSymbolID())
           }),
           let wireName = wires.first?.name {
            return "\(typeName)  '\(wireName.resolveSymbol())'"
        }

        return typeName
    }

    /// The lines for one node's errors: a heading, then one entry per distinct message.
    ///
    /// Grouped by message rather than by port, because a node that fails usually fails on all
    /// of its ports at once with the same reason — `errorLog, infoLog, output: …` says that in
    /// one line, where a line per port says the same thing three times and buries how many
    /// distinct problems there actually are.
    ///
    /// `messages` is the caller's selection. Passing fewer than the node has is how the engine
    /// reports only what is new.
    public static func entry(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer) -> Entry {
        let items = messages.sorted().map { message -> Item in
            let portNames = ports
                .filter { ((try? $0.dataObjectHash?.resolveAsString()) ?? "") == message }
                .map { $0.nameSymbolID.resolveSymbol() }
                .sorted()
            return Item(ports: portNames, message: message)
        }
        return Entry(label: label(forNodeID: nodeID, database: database), items: items)
    }

    /// The lines for one entry: a heading, then one line per item, or an indented block
    /// when a message spans lines. `SemelCLI` has a twin of this over the wire record; the
    /// two must stay identical, and `IdleErrorReportingTests` pins this one's output.
    public static func lines(for entry: Entry) -> [String] {
        var result = ["❌ \(entry.label)"]

        for item in entry.items {
            let portNames = item.ports.joined(separator: ", ")

            let body = item.message
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

        result.append("")
        return result
    }

    public static func lines(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer) -> [String] {
        lines(for: entry(forNodeID: nodeID, ports: ports, messages: messages, database: database))
    }

    /// The message a port is carrying, or nil when it carries nothing worth reporting.
    ///
    /// `initializing` is the placeholder every node holds between being created and first
    /// processing, so reporting it would announce an error for every node in a fresh graph.
    public static func reportableMessage(of port: OutputPort) -> String? {
        let message = (try? port.dataObjectHash?.resolveAsString()) ?? ""
        return message.isEmpty || message == "initializing" ? nil : message
    }
}
