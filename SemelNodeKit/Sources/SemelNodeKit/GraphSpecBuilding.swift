// GraphSpecBuilding.swift
// SemelNodeKit
//
// Building a spec in code (B-115). Text is for what a person writes or reads; between
// components there are trees. A node that asks for wires builds them from node types and
// port constants, so a quoting mistake cannot compile and nothing parses anything back.

public extension GraphSpecNode {

    /// A node of `type` with these properties and, per static input port, per wire name,
    /// the tree each wire comes from. The type's name is what the tree carries — that is
    /// what a formula carries too — and the registry turns it back into the kind the
    /// identity is taken over. Sorted here, so the order a dictionary happens to give is
    /// never the order two otherwise equal trees differ in.
    init(_ type: any WithKind.Type, properties: [String: String] = [:], inputs: [String: [String: GraphSpecNode]] = [:]) {
        self.init(typeName: String(describing: type),
                  properties: properties.sorted { $0.key < $1.key }.map { GraphSpecProperty(key: $0.key, value: $0.value) },
                  inputs: inputs.sorted { $0.key < $1.key }.map { port in
                      GraphSpecInputPort(portName: port.key,
                                         wires: port.value.sorted { $0.key < $1.key }.map { GraphSpecWire(name: $0.key, node: $0.value) })
                  })
    }

    /// The same tree read at `port`: what a wire's source is, where a bare tree is a node.
    func port(_ port: String) -> GraphSpecNode {
        GraphSpecNode(typeName: typeName, properties: properties, inputs: inputs, outputs: outputs, outputPort: port)
    }

    /// This node with the modes of its files wired beside them, where its type asks for
    /// them (`NodeDescriptor.fileMetadataInputPorts`): each wire on a file port whose source
    /// publishes `fileMetadata`, and is read at the port that metadata describes, gains a
    /// wire of the same name on the metadata port, from that source's `fileMetadata`.
    ///
    /// A wire rather than a read of the source when the node processes: the mode is then an
    /// input like the bytes, so it is in the node's cache key and a mode that changes under
    /// the same bytes wakes the node. Filled here, where a spec is built, because a formula
    /// cannot pick a port off a value a func was handed, and a spec built in code should
    /// not have to remember. A metadata port the spec already wires is left as it is. One
    /// level: the formula resolver calls this on every node it builds.
    func wiringFileMetadata() -> GraphSpecNode {
        guard let nodeType = TypeRegistry.nodeType(forTypeName: typeName) as? any Node.Type else {
            return self
        }
        var wiredInputs = inputs
        for (filePort, metadataPort) in nodeType.descriptor.fileMetadataInputPorts.sorted(by: { $0.key < $1.key })
            where !wiredInputs.contains(where: { $0.portName == metadataPort }) {
            let fileWires = wiredInputs.first { $0.portName == filePort }?.wires ?? []
            let metadataWires = fileWires.compactMap { wire -> GraphSpecWire? in
                guard wire.node.outputPort == FileMetadata.describedPortName,
                      let sourceType = TypeRegistry.nodeType(forTypeName: wire.node.typeName) as? any Node.Type,
                      sourceType.descriptor.outputPorts.contains(FileMetadata.portName) else {
                    return nil
                }
                return GraphSpecWire(name: wire.name, node: wire.node.port(FileMetadata.portName))
            }
            if !metadataWires.isEmpty {
                wiredInputs.append(GraphSpecInputPort(portName: metadataPort, wires: metadataWires))
            }
        }
        return GraphSpecNode(typeName: typeName, properties: properties, inputs: wiredInputs,
                             outputs: outputs, outputPort: outputPort)
    }
}

/// The two file-system nodes every toolchain asks for, by the names the engine registers
/// them under. The types live in the engine, which a toolchain package does not import;
/// the names are the interface, and the engine's tests pin them to the types.
public enum FileSystemNodes {
    public static let staticFileTypeName = "StaticFile"
    public static let staticFileOutputPort = "output"
    public static let folderTypeName = "Folder"
    public static let folderManifestPort = "manifest"
    public static let folderContentRootPort = "contentRoot"
    public static let folderSubtreeManifestPort = "subtreeManifest"
}

/// The three settings nodes a toolchain wires its tools' configuration through, by the
/// names and ports the engine registers them under — pinned to the types by the engine's
/// tests, as `FileSystemNodes` is. A toolchain that demands a configured node builds this
/// stack rather than writing it out.
public enum SettingsNodes {
    public static let settingsLiteralTypeName = "SettingsLiteral"
    public static let settingsLiteralOutputPort = "output"
    public static let configFilterTypeName = "ConfigFilter"
    public static let configFilterPrefixProperty = "prefix"
    public static let configFilterInputPort = "input"
    public static let configFilterOutputPort = "output"
    public static let configMergerTypeName = "ConfigMerger"
    public static let configMergerBasePort = "base"
    public static let configMergerOverridePort = "override"
    public static let configMergerOutputPort = "output"
    /// The wire names of a merger laying literals over settings, as `literals(_:over:)`
    /// builds it and the converters write it: one name each, so the tree built in code and
    /// the text written in a formula name the same node.
    public static let literalsBaseWire = "settings"
    public static let literalsOverrideWire = "literals"
}

public extension GraphSpecNode {

    /// `SettingsLiteral(<literals>)`, read at its output: the literals as settings.
    static func settingsLiteral(_ literals: [String: String]) -> GraphSpecNode {
        GraphSpecNode(typeName: SettingsNodes.settingsLiteralTypeName,
                      properties: literals.sorted { $0.key < $1.key }.map { GraphSpecProperty(key: $0.key, value: $0.value) },
                      outputPort: SettingsNodes.settingsLiteralOutputPort)
    }

    /// `literals` laid over `settings`: `ConfigMerger(base: ['settings': <settings>],
    /// override: ['literals': SettingsLiteral(<literals>).output]).output`, so what a formula
    /// states about a target wins over what a config file says (B-120). With no literals it
    /// is `settings` itself — a merger over nothing would be one node more for the same text.
    static func literals(_ literals: [String: String], over settings: GraphSpecNode) -> GraphSpecNode {
        guard !literals.isEmpty else {
            return settings
        }
        return .configMerger(base:     [SettingsNodes.literalsBaseWire: settings],
                             override: [SettingsNodes.literalsOverrideWire: .settingsLiteral(literals)])
    }

    /// `ConfigFilter(prefix:, input: [...])`, read at its output: one namespace's slice of
    /// the settings wired in.
    static func configFilter(prefix: String, input: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(typeName: SettingsNodes.configFilterTypeName,
                      properties: [GraphSpecProperty(key: SettingsNodes.configFilterPrefixProperty, value: prefix)],
                      inputs: [GraphSpecInputPort(portName: SettingsNodes.configFilterInputPort,
                                                  wires: input.sorted { $0.key < $1.key }.map { GraphSpecWire(name: $0.key, node: $0.value) })],
                      outputPort: SettingsNodes.configFilterOutputPort)
    }

    /// `ConfigMerger(base: [...], override: [...])`, read at its output: the override laid
    /// over the base.
    static func configMerger(base: [String: GraphSpecNode], override: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(typeName: SettingsNodes.configMergerTypeName,
                      inputs: [GraphSpecInputPort(portName: SettingsNodes.configMergerBasePort,
                                                  wires: base.sorted { $0.key < $1.key }.map { GraphSpecWire(name: $0.key, node: $0.value) }),
                               GraphSpecInputPort(portName: SettingsNodes.configMergerOverridePort,
                                                  wires: override.sorted { $0.key < $1.key }.map { GraphSpecWire(name: $0.key, node: $0.value) })],
                      outputPort: SettingsNodes.configMergerOutputPort)
    }
}

public extension GraphSpecNode {

    /// A pushed file's bytes: `StaticFile(path:)`, read at its output.
    static func staticFile(at path: String) -> GraphSpecNode {
        GraphSpecNode(typeName: FileSystemNodes.staticFileTypeName,
                      properties: [GraphSpecProperty(key: "path", value: path)],
                      outputPort: FileSystemNodes.staticFileOutputPort)
    }

    /// A pushed folder's manifest — what it holds, by name — read at its manifest port.
    static func folderManifest(at path: String) -> GraphSpecNode {
        GraphSpecNode(typeName: FileSystemNodes.folderTypeName,
                      properties: [GraphSpecProperty(key: "path", value: path)],
                      outputPort: FileSystemNodes.folderManifestPort)
    }

    /// A pushed folder's content root — the Merkle root of everything under it (B-26) —
    /// read at its content-root port. The same folder node as `folderManifest(at:)`; a
    /// wire to this port re-runs its consumer on any change below the folder, which is
    /// what a consumer asking for it wants and what one asking for names does not.
    static func folderContentRoot(at path: String) -> GraphSpecNode {
        GraphSpecNode(typeName: FileSystemNodes.folderTypeName,
                      properties: [GraphSpecProperty(key: "path", value: path)],
                      outputPort: FileSystemNodes.folderContentRootPort)
    }

    /// A pushed folder's subtree manifest — what it holds at every depth, by name (B-135) —
    /// read at its subtree-manifest port. The same folder node again. One wire answers for
    /// the whole tree on the next pass, where a walk over manifests was a wire and a pass
    /// per level; `FolderSubtreeManifest.folderManifests(at:)` reads it back as the
    /// manifests such a walk would have gathered. Keyed, like every demand of a folder, by
    /// the folder's path, which is what that reading is given.
    static func folderTree(at path: String) -> GraphSpecNode {
        GraphSpecNode(typeName: FileSystemNodes.folderTypeName,
                      properties: [GraphSpecProperty(key: "path", value: path)],
                      outputPort: FileSystemNodes.folderSubtreeManifestPort)
    }
}
