//
//  Folder.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

struct FolderManifestEntry: Codable {
    let name: String
    let isFolder: Bool
}

struct FolderManifest: PolySerializable {
    static let kind: UInt = 4

    let entries: [FolderManifestEntry]
}

struct Folder: InputlessNodeFunction {
    static let kind: UInt = 1

    var embeddedNode: Node?
    let containingPath: String
    let name: String

    enum CodingKeys: CodingKey {
        case containingPath
        case name
    }

    var initialName: String? {
        name
    }

    init(thisNode: Node) {
        embeddedNode = thisNode
        let properties = [String: String](plainText: thisNode.encodedProperties ?? "")
        let path = properties["path"]!
        assert(!path.hasPrefix("/"))
        assert(!path.hasSuffix("/"))
        containingPath = path.deletingLastPathComponent() ?? ""
        name = path.lastPathComponent
    }

    init(properties: [String : String] = [String: String]()) {
        let path = properties["path"]!
        assert(!path.hasPrefix("/"))
        assert(!path.hasSuffix("/"))
        containingPath = path.deletingLastPathComponent() ?? ""
        name = path.lastPathComponent
        assert(self.path == path)
    }

    var properties: [String : String] {
        ["path": path]
    }

    func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest().toJSON().intern())],
              inputWireExpectations: [:])
    }

    var path: String {
        containingPath.appendingPathComponent(name)
    }

    func canBeDeleted() throws -> Bool {
        try thisNode.allChildren.isEmpty
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [folderManifestOutputPort], dynamicInputPorts: [])

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(newChildNode: Node) throws {
        try refreshOutputs()
    }

    func notifyChildContentChanged(nodeID: ObjectID, name: String) throws {
        try refreshOutputs()
    }

    private func buildManifest() throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()

        for child in try thisNode.allChildren {

            // Hide ghosts
            if let staticFile = try child.nodeFunction() as? StaticFile {
                if try staticFile.isGhost() {
                    continue
                }
            }

            folderManifestEntries.append(.init(name: child.name!, isFolder: child.kind == Folder.kind))
        }

        return .init(entries: folderManifestEntries)
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest().toJSON().intern()))
    }
}
