//
//  DebugPrint.swift
//  semel
//

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

/// Collects the lines of a diagnostic so the whole thing can be returned as one string.
/// Debug output must never be the thing that takes the process down, so nothing here
/// throws; a caller that cannot describe part of the graph appends what it can say.
final class TextBuffer {
    private(set) var lines: [String] = []

    func append(_ line: String = "") {
        lines.append(line)
    }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - String helpers

extension String {
    fileprivate func replacingNonprintableCharacters() -> String {
        map { char -> String in
            char.isASCII ? (char.isNewline ? "\\n" : String(char)) : "�"
        }.joined()
    }

    func truncated(to maxLength: Int = 80) -> String {
        count > maxLength ? String(prefix(maxLength)) + "…" : self
    }
}

// MARK: - printAll

extension BuildEngine {

    // MARK: Private helpers

    /// Format raw bytes as a quoted UTF-8 string, or hex if not valid UTF-8.
    private func formatBytes(_ bytes: [UInt8]?) -> String {
        guard let bytesUnlimited = bytes else {
            return "nil"
        }

        let bytes = bytesUnlimited.prefix(128)

        if let string = String(bytes: bytes, encoding: .utf8) {
            return "\"\(string.replacingNonprintableCharacters().truncated())\""
        }
        return bytes.asHex().truncated()
    }

    /// Resolve a DataObjectHash to its content and format it.
    private func formatHash(_ hash: DataObjectHash?) -> String {
        formatBytes(try? hash?.resolve())
    }

    /// Resolve a symbol ID to its name, falling back to "?".
    ///
    /// Every database read in this file is best effort — debug output must never be the
    /// thing that takes the process down — but a machine failure still reaches the fatal
    /// handler, which is what `FatalErrors.attempt` adds over `try?`.
    private func symbolName(symbolID: ObjectID, database: DatabaseLayer) -> String {
        (FatalErrors.attempt({ try database.symbol.select(symbolID: symbolID) }) ?? nil)?.name ?? "<invalid symbolID>"
    }

    /// Format a wire as "fromNode:fromPort ──▶ toNode:toPort".
    private func formatWire(_ wire: Wire, nodeByID: [ObjectID: NodeRecord], database: DatabaseLayer) -> String {
        let fromNode = nodeByID[wire.fromNodeID]?.name ?? "?"
        let toNode   = nodeByID[wire.toNodeID]?.name   ?? "?"
        let fromPort = symbolName(symbolID: wire.fromSymbolID, database: database)
        let toPort   = symbolName(symbolID: wire.toSymbolID,   database: database)
        return "\(fromNode):\(fromPort)  ──▶  \(toNode):\(toPort)"
    }

    /// Format an output port value with an emoji status prefix.
    func formatOutputPort(_ outputPort: SemelDatabaseModels.OutputPort) -> String {
        switch outputPort.valueKind {
        case .value:
            let hash    = outputPort.dataObjectHash ?? "nil"
            let preview = formatHash(outputPort.dataObjectHash)
            return "[ \(hash.truncated(to: 12))  \(preview.truncated(to: 20)) ]"
        case .pending:
            return "[ 🟡 pending ]"
        case .initializing:
            return "[ 🟡 \(NoValueReason.initializing) ]"
        case .inputNotProduced:
            return "[ 🟡 \(NoValueReason.inputNotProduced) ]"
        case .inputInError:
            return "[ ❌ \(NoValueReason.inputInError) ]"
        case .deleted:
            return "[ ❌ \(NoValueReason.deleted) ]"
        case .error:
            let message = (try? outputPort.dataObjectHash?.resolveAsString()) ?? "<no message>"
            return "[ ❌ \(message) ]"
        }
    }

    /// Append a titled section header.
    private func appendSectionHeader(_ title: String, to text: TextBuffer) {
        text.append(title)
        text.append(String(repeating: "─", count: title.count))
    }

    // MARK: nudge

    public func nudge() throws {
        _ = try database.cacheEntry.deleteAll()
        // Reset all Node outputs to pending so downstream nodes block on
        // stale values and wait for fresh upstream results (correct ordering).
        for nodeRecord in try database.node.selectAll() {
            guard let node = try? nodeRecord.makeNode(),
                  type(of: node).descriptor.hasInputs else { continue }
            try nodeRecord.writePendingToAllOutputsOfNode()
        }
        for nodeRecord in try database.node.selectAll() {
            try nodeRecord.setScheduled(true)
        }
    }

    // MARK: cacheEntryDescription

    /// One cache entry's key material: the text its key is the hash of, printed whole so
    /// that two machines that disagreed about a build compare two of these instead of two
    /// hashes, and so that `shasum -a 256` over the printed block answers the key above it.
    ///
    /// Beside `graphDescription` because it answers the same verb and obeys the same rule:
    /// diagnostic output never throws, so an entry that cannot be read is described rather
    /// than raised.
    public func cacheEntryDescription(key: String) -> String {
        guard let cacheEntry = (FatalErrors.attempt { try database.cacheEntry.select(hash: key) }) ?? nil else {
            return "There is no cache entry under the key \(key)."
        }

        let text = TextBuffer()
        appendSectionHeader("cache entry \(key)", to: text)
        text.append("node type: \(cacheEntry.nodeType)")
        text.append("cost: \(cacheEntry.cost) ms")
        text.append("last used by settle: \(cacheEntry.lastUse)")
        if let size = (FatalErrors.attempt { try database.cacheEntry.sizes() })?.first(where: { $0.hash == key }) {
            text.append("held only by this entry: \(ByteCount(bytes: size.bytes))"
                      + (size.heldByNode ? ", and a node of the graph holds its outputs" : ""))
        }
        text.append()

        guard let decoded = try? ProcessCacheEntry.fromJSON(String(decoding: cacheEntry.content, as: UTF8.self)),
              let material = try? decoded.keyMaterial.canonicalText() else {
            text.append("Its content is not of a shape this Semel reads, so the material its key was "
                      + "taken of cannot be shown. The entry is a miss and the next build of that node "
                      + "replaces it.")
            return text.text
        }

        // Said only when it does not hold: the material is what the key was taken of, so a
        // disagreement is a damaged row and worth a line of its own.
        if let recomputed = try? decoded.keyMaterial.cacheKey(), recomputed != key {
            text.append("The material below hashes to \(recomputed), which is not the key this entry "
                      + "is filed under. The entry is damaged.")
            text.append()
        }

        text.append("key material — its sha256 is the key above:")
        // Without the text's own final newline, which the printing of this description puts
        // back: what a reader pipes into `shasum -a 256` is then the bytes that were hashed,
        // to the byte, and the claim on the line above holds outside this process.
        text.append(material.hasSuffix("\n") ? String(material.dropLast()) : material)
        return text.text
    }

    // MARK: graphDescription

    public func graphDescription() throws -> String {
        let text = TextBuffer()
        let allNodes = try database.node.selectAll()
        let allWires = try database.wire.selectAll()

        // Indexes built once and reused throughout
        let nodeByID: [ObjectID: NodeRecord] = Dictionary(
            uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let wiresByToNodeID:   [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.toNodeID)
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: \.fromNodeID)

        // A handful of port names name every wire in the graph, and a node's output ports
        // are read both for its own section and for every wire that starts at it. Both are
        // resolved once per distinct key rather than once per line.
        var resolvedSymbolNames: [ObjectID: String] = [:]
        func portName(_ symbolID: ObjectID) -> String {
            if let known = resolvedSymbolNames[symbolID] {
                return known
            }
            let resolved = symbolName(symbolID: symbolID, database: database)
            resolvedSymbolNames[symbolID] = resolved
            return resolved
        }

        var outputPortsByNodeID: [ObjectID: [SemelDatabaseModels.OutputPort]] = [:]
        func outputPortRows(of nodeID: ObjectID) -> [SemelDatabaseModels.OutputPort] {
            if let known = outputPortsByNodeID[nodeID] {
                return known
            }
            let ports = FatalErrors.attempt({ try database.outputPort.selectAll(nodeID: nodeID) }) ?? []
            outputPortsByNodeID[nodeID] = ports
            return ports
        }

        // MARK: Section 1 — Nodes

        appendSectionHeader("BUILD GRAPH STATE (\(allNodes.count) nodes)", to: text)
        text.append()

        for nodeRecord in allNodes {
            guard let nodeID = nodeRecord.id else { continue }

            // Built once and used for both the type name and the descriptor: instantiating
            // a node decodes its properties, and a few hundred nodes make that a cost.
            let node = try? nodeRecord.makeNode()
            let scheduled = nodeRecord.scheduled ? "⏱ scheduled" : ""
            text.append("⬢ \(node.map { String(describing: type(of: $0)) } ?? "kind \(nodeRecord.kind)?") #\(nodeID)  \(scheduled)")

            if let name = nodeRecord.name {
                text.append("  name: '\(name)'")
            }

            // Eight characters (B-115): enough to tell nodes apart in a dump; the wire
            // lines below name each source by the same prefix.
            text.append("  identity: \(nodeRecord.identity.map(NodeIdentity.shown) ?? "nil")")

            if let parentNodeID = nodeRecord.parentNodeID {
                text.append("  parent: \(nodeByID[parentNodeID]?.name ?? "?") #\(parentNodeID)")
            }

            let descriptor    = node?.descriptor
            let inputPorts    = (descriptor?.staticInputPorts  ?? []) + (descriptor?.dynamicInputPorts ?? [])
            let outputPorts   =  descriptor?.outputPorts ?? []
            let incomingWires = wiresByToNodeID[nodeID]   ?? []
            let outgoingWires = wiresByFromNodeID[nodeID] ?? []
            let outputValues  = outputPortRows(of: nodeID)

            if !inputPorts.isEmpty {
                text.append("  inputs:")
                for inputPort in inputPorts {
                    let dynamic = descriptor?.dynamicInputPorts.contains(inputPort) == true ? " (dynamic)" : ""
                    let inputSymbolID = inputPort.asSymbolID()
                    let wires   = incomingWires.filter { $0.toSymbolID == inputSymbolID }
                    if wires.isEmpty {
                        text.append("    · \(inputPort)\(dynamic)  — no wires")
                    } else {
                        for wire in wires {
                            let source = nodeByID[wire.fromNodeID]
                            let fromNode = "\(source?.name ?? "?") [\(source?.identity.map(NodeIdentity.shown) ?? "?")]"
                            let fromPort = portName(wire.fromSymbolID)
                            let outputPort = outputPortRows(of: wire.fromNodeID)
                                .first { $0.nameSymbolID == wire.fromSymbolID }
                            let outputValue = outputPort.map { formatOutputPort($0) } ?? "—"
                            text.append("    · \(inputPort)\(dynamic)  ◀──(\(wire.name.resolveSymbol()))── #\(wire.fromNodeID) \(fromNode):\(fromPort)   \(outputValue)")
                        }
                    }
                }
            }

            if !outputPorts.isEmpty {
                text.append("  outputs:")
                for outputPort in outputPorts {
                    let symbolID   = outputPort.asSymbolID()
                    let wires      = outgoingWires.filter { $0.fromSymbolID == symbolID }
                    let portValue  = outputValues.first { $0.nameSymbolID == symbolID }
                    let valueDesc  = portValue.map { formatOutputPort($0) } ?? "—"
                    if wires.isEmpty {
                        text.append("    · \(outputPort)  \(valueDesc)  — no wires")
                    } else {
                        for wire in wires {
                            let toNode = nodeByID[wire.toNodeID]?.name ?? "?"
                            let toPort = portName(wire.toSymbolID)
                            text.append("    · \(outputPort)  \(valueDesc)  ────▶ #\(wire.toNodeID) \(toNode):\(toPort)")
                        }
                    }
                }
            }

            text.append()
        }

        // Debug output must never be the thing that takes the process down.
        let outputPortCount = FatalErrors.attempt({ try database.outputPort.selectAllCount() }).map(String.init) ?? "unavailable"
        text.append("OutputPort count: \(outputPortCount)\n")

        appendDependencyTree(to: text)
        return text.text
    }

    @discardableResult
    func appendDependencyTree(to text: TextBuffer) -> DependencyTreeWalk {
        let walk = DependencyTreeWalk()
        do {
            text.append("- build tree")
            try projectFinder.appendDependencyTree(indentLevel: 1, walk: walk, to: text)
        } catch {
            text.append("- build tree (error: \(error))")
        }
        return walk
    }
}

/// One walk of the dependency tree, and the nodes it has rendered.
///
/// The set belongs to the walk rather than to each node's recursion, because the
/// dependencies are a graph and not a tree: a header wired into a thousand compiles is one
/// node reached a thousand ways. A set per node makes the walk enumerate the graph's
/// *paths*, whose number grows with every shared dependency, so a few hundred nodes are
/// already more paths than a prompt can wait for.
///
/// How many nodes the walk has entered is what the cost tests assert on: a timing cannot
/// tell a walk that grew from a walk that ran on a busy machine.
final class DependencyTreeWalk {

    private(set) var visits = 0
    private var renderedNodeIDs = Set<ObjectID>()

    func enter() {
        visits += 1
    }

    /// True the first time a node is reached, false for every encounter after that.
    func shouldRender(_ nodeID: ObjectID) -> Bool {
        renderedNodeIDs.insert(nodeID).inserted
    }
}

extension NodeRecord {

    fileprivate func appendDependencyTree(indentLevel: Int, walk: DependencyTreeWalk, to text: TextBuffer) {
        walk.enter()
        let indent = String(repeating: "  ", count: indentLevel)

        // Debug output must never be the thing that takes the process down: an
        // unregistered kind here means the tree prints "kind 27?" rather than crashing.
        let kindName = (try? makeNode()).map { String(describing: type(of: $0)) }
                    ?? "kind \(kind)?"

        let nodeName = name ?? ""

        guard let nodeID = id else {
            text.append("\(indent)- \(kindName)(\(nodeName)) [unsaved]")
            return
        }

        // A node reached again is the same node, and its dependencies are printed where it
        // was first reached; a reference costs one line where the subtree costs a copy of
        // everything under it, once per consumer.
        guard walk.shouldRender(nodeID) else {
            text.append("\(indent)- \(kindName)(\(nodeName)) \(nodeID)  (see above)")
            return
        }

        text.append("\(indent)- \(kindName)(\(nodeName)) \(nodeID)")

        do {
            let incomingWires = try database.wire.select(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [NodeRecord]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: wire.fromNodeID) }) ?? nil {
                    dependencyNodes.append(nodeRecord)
                }
            }

            for dependencyNode in dependencyNodes {
                dependencyNode.appendDependencyTree(indentLevel: indentLevel + 1, walk: walk, to: text)
            }
        } catch {
            text.append("\(indent)  (error loading dependencies: \(error))")
        }
    }
}
