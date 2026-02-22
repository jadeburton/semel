//
//  FileSystem.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

final class FileSystem: NodeType {
    static let kind: UInt = 1

    var nodeContext: NodeContext!
    var dynamicOutputs: [NodeKindDescriptor.Port]

    enum CodingKeys: String, CodingKey {
        case dynamicOutputs
    }

    required init() {
        dynamicOutputs = [
            .init(index: 0, name: "output", kind: .persistentValue(dataType: .binary))
        ]
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dynamicOutputs = try container.decode([NodeKindDescriptor.Port].self, forKey: .dynamicOutputs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dynamicOutputs, forKey: .dynamicOutputs)
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: dynamicOutputs)
    }

    func handleCommand(_ command: String) throws {
        // push [file]
        // rm [file]
    }

    private func push(externalFilePath: String) {
        // locate the file in the external file system
        // read the file
        let fileContent = try! Data(contentsOf: URL(fileURLWithPath: externalFilePath)).bytes
        // if it does not already exist, synchronously create a new Node representing this file in the internal file system

        // if it does already exist, write to its input port with the file content, which should cause it to emit mutation events if the content has changed
        // creating a new Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
        // mutation events will be queued on other Nodes that are subscribed
    }

    private func remove() {
        // locate the file or folder in the internal file system
        // if it does not exist, report error to user
        // if it is a folder, recursively remove all files and folders inside
        // remove the Node representing this file or folder from the internal file system
        // deleting a Node will cause its parent folder to emit mutation events, and its parent, all the way to the root folder
        // deleting a Node that has Wires will cause wire-removed events for wire targets
        // mutation events will be queued on other Nodes that are subscribed
    }

    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?] {
        [:]
    }
}
