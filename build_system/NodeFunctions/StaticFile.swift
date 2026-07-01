//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

// StaticFile only exists within the input file system hierarchy. It provides a connection to the outside world,
// allowing users to push files into the build system and have them be used as inputs to other Nodes. It is a leaf
// node and cannot have inputs.
struct StaticFile: InputlessNodeFunction, FileType, HasPath {
    static let kind: UInt = 3

    func isGhost() throws -> Bool {
        guard let nodeValue = try read() else {
            return true
        }

        return nodeValue.isNoValue
    }

    static let outputPort = "output"

    var embeddedNode: Node?

    var path: String {
        thisNode.properties["path"]!
    }

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        embeddedNode!.name = name
        embeddedNode!.parentNodeID = try inputFileSystem.ensureEntirePathExistsAsFolders(containingPath).id!
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [outputPort])

    var inputFileSystem: Node {
        get throws {
            try BuildEngine.shared.inputFileSystem
        }
    }

    // If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    // it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted
    // if there are no output Wires.
    func canBeDeleted() throws -> Bool {
        try isGhost()
    }

    func read() throws -> NodeValue? {
        try thisNode.readFromOutputPort(Self.outputPort)
    }

    func replaceContent(_ content: DataObjectHash?) throws -> Bool {
        let changed: Bool

        if let content {
            changed = try thisNode.writeToOutputPort(Self.outputPort, value: .value(content))
        } else {
            changed = try thisNode.writeToOutputPort(Self.outputPort, value: .noValue(reason: .error(message: "File deleted")))
        }

        if let parentNodeID {
            let parentFolderNode = try database.node.select(nodeID: parentNodeID)
            try (parentFolderNode.nodeFunctionCast() as Folder).notifyChildContentChanged(nodeID: id!, name: name)
        }

        return changed
    }
}

protocol FileType {
    func read() throws -> NodeValue?
}
