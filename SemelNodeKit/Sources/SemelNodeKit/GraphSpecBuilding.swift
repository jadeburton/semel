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
}

/// The two file-system nodes every toolchain asks for, by the names the engine registers
/// them under. The types live in the engine, which a toolchain package does not import;
/// the names are the interface, and the engine's tests pin them to the types.
public enum FileSystemNodes {
    public static let staticFileTypeName = "StaticFile"
    public static let staticFileOutputPort = "output"
    public static let folderTypeName = "Folder"
    public static let folderManifestPort = "manifest"
}

/// The three settings nodes a toolchain wires its tools' configuration through, by the
/// names and ports the engine registers them under — pinned to the types by the engine's
/// tests, as `FileSystemNodes` is. A toolchain that demands a configured node builds this
/// stack rather than writing it out.
public enum SettingsNodes {
    public static let configurationTypeName = "Configuration"
    public static let configurationBasePort = "base"
    public static let configurationOutputPort = "output"
    public static let configFilterTypeName = "ConfigFilter"
    public static let configFilterPrefixProperty = "prefix"
    public static let configFilterInputPort = "input"
    public static let configFilterOutputPort = "output"
    public static let configMergerTypeName = "ConfigMerger"
    public static let configMergerBasePort = "base"
    public static let configMergerOverridePort = "override"
    public static let configMergerOutputPort = "output"
}

public extension GraphSpecNode {

    /// `Configuration(<literals>, base: [...])`, read at its output: the settings it is
    /// handed with the literals laid over them.
    static func configuration(literals: [String: String], base: [String: GraphSpecNode]) -> GraphSpecNode {
        GraphSpecNode(typeName: SettingsNodes.configurationTypeName,
                      properties: literals.sorted { $0.key < $1.key }.map { GraphSpecProperty(key: $0.key, value: $0.value) },
                      inputs: [GraphSpecInputPort(portName: SettingsNodes.configurationBasePort,
                                                  wires: base.sorted { $0.key < $1.key }.map { GraphSpecWire(name: $0.key, node: $0.value) })],
                      outputPort: SettingsNodes.configurationOutputPort)
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
}
