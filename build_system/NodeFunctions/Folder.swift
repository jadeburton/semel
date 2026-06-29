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

    let containingPath: String
    let name: String

    enum CodingKeys: CodingKey {
        case containingPath
        case name
    }

    var initialName: String? {
        name
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

    func didCreate(thisNode: Node) throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest(thisNode: thisNode).toJSON().intern())],
              inputWireExpectations: [:])
    }

    var path: String {
        containingPath.appendingPathComponent(name)
    }

    func canBeDeleted(thisNode: Node) throws -> Bool {
        try thisNode.allChildren.isEmpty
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [folderManifestOutputPort], dynamicInputPorts: [])

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(newChildNode: Node, thisNode: Node) throws {
        try refreshOutputs(thisNode: thisNode)
    }

    func notifyChildContentChanged(nodeID: ObjectID, name: String, thisNode: Node) throws {
        try refreshOutputs(thisNode: thisNode)
    }

    private func buildManifest(thisNode: Node) throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()

        for child in try thisNode.allChildren {

            // Hide ghosts
            if let staticFile = try child.nodeFunction() as? StaticFile {
                if try staticFile.isGhost(thisNode: child) {
                    continue
                }
            }

            folderManifestEntries.append(.init(name: child.name!, isFolder: child.kind == Folder.kind))
        }

        return .init(entries: folderManifestEntries)
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs(thisNode: Node) throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest(thisNode: thisNode).toJSON().intern()))
    }
}
