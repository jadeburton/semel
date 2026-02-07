//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import GRDB
import DatabaseModels

extension Database {

    func removeAllWiresBetweenNodes(firstNodeID: ObjectID, secondNodeID: ObjectID) throws {
    }

    func findAllParentFoldersOfFileOrFolder(childFileOrFolderNodeID: ObjectID) throws -> [Node] {
        []
    }
}

extension Node {
    func description() -> String {
        "Node \(id ?? -1): kind \(kind), configuration: \(String(describing: configuration))"
    }
}
/*
final class FileSystem {
    private let database: Database

    init (database: Database) {
        self.database = database
    }

    func importAll(basePath: String) throws {
        // There is only one file system, but it may have many root directories that map to different locations outside
//        let fileSystemID = try! database.insertOrGetExistingGraph(name: "fs", kind: .fileSystem, pluginCreator: nil)

        var fileSystemNodeID = try database.selectRootFolder(name: "input")?.id

        if fileSystemNodeID == nil {
            fileSystemNodeID = try database.insertNode(.init(content: .folder(name: "input", parentFolderID: nil/*, kind: .folder*/)))
        }

        importAll(basePath: basePath, fileSystemNodeID: fileSystemNodeID!)
    }

    private func importAll(basePath: String, fileSystemNodeID: ObjectID) {
        // TODO: transactional
        recurseAllFilesBeneathDirectory(rootDirectoryPath: basePath,
                                        createRootFolder: { name in

            let existing = try? database.selectFileInFolder(folderNodeID: fileSystemNodeID, name: name)

            if let existing {
                return existing.id!
            }

            return try! database.insertNode(.init(content: .folder(name: name, parentFolderID: fileSystemNodeID/*, kind: .folder*/)))

        }, createFolder: { name, insideFolderID in

            let existing = try? database.selectFileInFolder(folderNodeID: insideFolderID, name: name)

            if let existing {
                return existing.id!
            }

            return try! database.insertNode(.init(content: .folder(name: name, parentFolderID: insideFolderID/*, kind: .folder*/)))

        }, createFile: { name, insideFolderID, content in

            let existing = try? database.selectFileInFolder(folderNodeID: insideFolderID, name: name)

            if existing != nil {
                return
            }

            let dataObjectID = try! database.addOrGetExistingDataObject(content: content)
            let nodeID = try! database.insertNode(.init(content: .staticFile(name: name, parentFolderID: insideFolderID/*, kind: .staticFile*/)))

            _ = try! database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: 0, dataObjectID: dataObjectID))

        }, excludeRule: { filename in
            filename == "cmake-build-debug"
        })
    }

    func recurseAllFilesBeneathDirectory(rootDirectoryPath: String,
                                         createRootFolder: (_ name: String) -> ObjectID,
                                         createFolder: (_ name: String, _ inside: ObjectID) -> ObjectID,
                                         createFile: (_ name: String, _ inside: ObjectID, _ content: [UInt8]) -> Void,
                                         excludeRule: (_ filename: String) -> Bool) {

        let fileManager = FileManager.default
        let baseURL = URL(fileURLWithPath: rootDirectoryPath)

        func recurse(url: URL, parent: URL?, parentFolderID: ObjectID?) {

            if excludeRule(url.lastPathComponent) {
                return
            }

            var isDir: ObjCBool = false

            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return
            }

            let name = url.lastPathComponent

            if isDir.boolValue {

                var newParentFolderID: ObjectID?

                if let parent {
                    newParentFolderID = createFolder(name, parentFolderID!)
                    print("ADD FOLDER \(name) TO FOLDER \(parent.lastPathComponent) \(parentFolderID ?? -1) --> \(newParentFolderID ?? -1)")
                } else {
                    newParentFolderID = createRootFolder(name)
                    print("ADD ROOT FOLDER \(name) --> \(newParentFolderID ?? -1)")
                }

                do {
                    let children = try fileManager.contentsOfDirectory(at: url,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles])

                    for child in children.sorted(by: { $0.path < $1.path }) {
                        recurse(url: child, parent: url, parentFolderID: newParentFolderID)
                    }
                } catch {
                    print("(error reading directory: \(error))")
                }
            } else {
                let s = parent?.lastPathComponent ?? "<root>"
                print("ADD FILE \(name) TO FOLDER \(s)")
                createFile(name, parentFolderID!, [UInt8](try! Data(contentsOf: url)))
            }
        }

        recurse(url: baseURL, parent: nil, parentFolderID: nil)
    }
}

func printFolderHierarchy(database: Database, folderNodeID: ObjectID, indent: String) {
    let children = try! database.selectAllFilesInFolder(folderNodeID: folderNodeID)

    for child in children {
        switch child.content {

        case .staticFile(let name, _):
            print("\(indent)- \(name)")

        case .folder(let name, _):
            print("\(indent)- \(name)")

            if let childFolderID = child.id {
                printFolderHierarchy(database: database, folderNodeID: childFolderID, indent: indent + "  ")
            }

        case .translator:
            break
        }
    }
}
*/
let database = try! Database(filePath: "database22.sqlite")

func main() throws {

//    let fileSystem = FileSystem(database: database)
//    try! fileSystem.importAll(basePath: "/Users/jadeburton/src/VerticalPager/VerticalPager")

    // There is only one meta graph
    // The meta graph is directly edited by plugins, which search for project files in the file system and create product graphs from them.
//    let metaGraphID = try! database.insertOrGetExistingGraph(name: "meta", kind: .metaGraph, parentGraphID: nil, pluginCreator: nil)

//    let pluginGraphID = try! database.insertOrGetExistingGraph(name: "plugin", kind: .metaGraph, parentGraphID: nil, pluginCreator: nil)

    // PRODUCT GRAPH CONFIGURATION OBJECT
    // 1. A yaml like tree
    // - mylibrary.dylib
    //   - input(s):
    //      - linker
    //        - input(s):
    //          - compiler
    //            - inputs:
    //              - preprocessors
    //                - inputs:
    //                  filea.h
    //                  filea.c
    //                  common.h
    //          - compiler
    //
    // 2. A functional syntax
    // VirtualFile(named: "mylibrary.dylib",
    //             inputs: [
    //                 Linker(inputs: [
    //                        Compiler(input: Preprocessor(inputs: ["/example/filea.c".output, "/example/common.h".output, "/example/filea.h".output]).output).output,
    //                        Compiler().output]).output
    //             ])
    //
    // 3. A flat series of objects and their relationships
    // product = VirtualFile(named: "mylibrary.dylib")
    // linker1 = Linker()
    // product.input <--> linker1.output
    // compiler1 = Compiler()
    // linker1.input[0] <--> compiler1.output
    // preprocessor1 = Preprocessor()
    // preprocessor1.input <--> "/example/filea.c".output
    // preprocessor1.input <--> "/example/common.h".output
    // preprocessor1.input <--> "/example/filea.h".output
    // compiler1.input <--> preprocessor1.output

//    try database.insertNode(.init(content: .fileSystemRoot(name: "Default")))
//    try database.deleteNode(4)
//    try database.insertNode(.init(content: .virtualFile(name: "myLib.dylib", sourceNodeSocketID: nil)))

//    try! database.selectAllRootFolders().forEach { folderNode in
//        print("Folder without parent: \(folderNode.description())")
//
//        printFolderHierarchy(database: database, folderNodeID: folderNode.id!, indent: "")
//    }

    for node in try database.selectAllNodes() {
        print("Node ID: \(node.description())")

        for wire in try database.selectWiresGoingToNode(node.id!) {
            let fromDesc = try? wire.fromNodeID.loadNode(from: database).description()
            print("    Wire (\(wire.id ?? -1)) from port \(wire.fromPort): \(fromDesc)")
        }
        for wire in try database.selectWiresComingFromNode(node.id!) {
            let toDesc = try? wire.toNodeID.loadNode(from: database).description()
            print("    Wire (\(wire.id ?? -1)) to port \(wire.toPort): \(toDesc)")
        }
    }
    
    //
}

enum NodeInputMessageKind {
    case didConnect(currentValue: DataObject?)
    case willDisconnect
    case inputChanged(newValue: DataObject?, oldValue: DataObject?)
    case error(description: String)
    case customEvent(dataObject: DataObject)
}

struct NodeInputMessage {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeInputMessageKind
}

enum NodeOutputMessage {
    case persistentValue(_ value: DataObject?)
    case event(_ event: DataObject)
}

protocol NodeType {
    var kind: UInt { get }
    var inputCount: UInt8 { get }
    var outputCount: UInt8 { get }

    init(nodeContext: NodeContext)

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage]
}

protocol World {
    var database: Database { get }

    func readValue(nodeID: ObjectID, inputPort: UInt8) -> DataObject?
    func assignValue(nodeID: ObjectID, outputPort: UInt8, value: DataObject?)
    func postEvent(nodeID: ObjectID, outputPort: UInt8, event: DataObject)

}

struct NodeContext {
    let world: World
    let nodeID: ObjectID
    let configuration: String?

    func readValue(inputPort: UInt8) -> DataObject? {
        world.readValue(nodeID: nodeID, inputPort: inputPort)
    }

    func assignValue(outputPort: UInt8, value: DataObject?) {
        world.assignValue(nodeID: nodeID, outputPort: outputPort, value: value)
    }

    func postEvent(outputPort: UInt8, event: DataObject) {
        world.postEvent(nodeID: nodeID, outputPort: outputPort, event: event)
    }
}

final class IngressNode: NodeType {
    let kind: UInt = 0
    let inputCount: UInt8 = 0
    var outputCount: UInt8 = 1
    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nodeContext.configuration
    }

    func assignValue(outputPort: UInt8, value: DataObject?) {
        nodeContext.assignValue(outputPort: outputPort, value: value)
    }

    func postEvent(outputPort: UInt8, event: DataObject) {
        nodeContext.postEvent(outputPort: outputPort, event: event)
    }

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage] {
        []
    }
}

final class EgressNode: NodeType {
    let kind: UInt = 1
    var inputCount: UInt8 = 1
    let outputCount: UInt8 = 0
    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nodeContext.configuration
    }

    func readValue(inputPort: UInt8) -> DataObject? {
        nodeContext.readValue(inputPort: inputPort)
    }

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage] {
        []
    }
}

final class NodeFactory {
    func makeNode(nodeContext: NodeContext, kind: UInt) -> NodeType {
        switch kind {

        case 0: return IngressNode(nodeContext: nodeContext)
        case 1: return EgressNode(nodeContext: nodeContext)

        default:
            fatalError("Unknown Node kind: \(kind)")
            break
        }
    }
}

final class Graph {
    func ensureIngressAndEgressExist(database: Database) {
//        database.selectNodeByID(<#T##nodeId: ObjectID##ObjectID#>)
    }
}

try main()

extension ObjectID {
    func loadNode(from database: Database) throws -> Node {
        guard let node = try database.selectNodeByID(self) else {
            throw Database.DatabaseError.nodeNotFound
        }
        return node
    }
}




// Graph
/*extension Database {

    func insertOrGetExistingGraph(name: String, kind: GraphKind, parentGraphID: ObjectID?, pluginCreator: String?) throws -> ObjectID {
        return try dbQueue.write { db in
            if let parentGraphID {
                if let existing = try Graph.fetchOne(db, sql: "SELECT * FROM Graph WHERE name = ? AND kind = ? AND parentGraphID = ?",
                                                     arguments: [name, kind.rawValue, parentGraphID]) {
                    return existing.id!
                }
            } else {
                if let existing = try Graph.fetchOne(db, sql: "SELECT * FROM Graph WHERE name = ? AND kind = ? AND parentGraphID IS NULL",
                                                     arguments: [name, kind.rawValue]) {
                    return existing.id!
                }
            }

            let graph = Graph(id: nil, name: name, pluginCreator: pluginCreator, kind: kind)
            try graph.insert(db)
            return db.lastInsertedRowID
        }
    }
}*/





// Strata: a differential build system. The goal is to eliminate top-to-bottom "build everything from scratch" processing and to only process the absolute minimum based on each source file change.

// TODO: when a change comes in, it should instantly and transactionally "make dirty" all nodes that are dependent on it, all the way to the end. However, we also need to "block" this dirty propagation if we detect that the change will not affect the output. For example, if a source file is changed but the imports/incudes do not change, the Meta graph should determine that no dependencies changed and therefore nothing downstream needs to be marked as dirty. It might require a concept of "forced inline execution" of certain kinds of Nodes when pushing files, with the remaining nodes working from the background queue. Why would we need forced and instant dirty-propagation? Because we need to immediately stop any Nodes from working if their input has changed, because they may be wasting their time. Also we need a way to know if an output product matches the latest input or if a build is in progress and it will be updated shortly.

// 1. Add or Update file: strata push myFile.c
// 2. Delete file/dir: strata delete myFile.c
// 3. Sync file/dir: strata sync ./myProjectDir
//
// 1. Add/Update
//    Locate corresponding file node in file system graph. If doesn't exist, create it.
//    Search for all subscriber Nodes.
//    Create a new Message object containing the content of the file added/updated, its path etc.
//    For each subscriber, insert a Message row referencing the Message (file created or updated) and the target node
//    For each subscriber, insert a Message row referencing the Message (directory child added or updated) and the target node (recursive for all parent folders)
// 2. Delete
//    Locate corresponding file node in file system graph. If doesn't exist, error.
//    Search for all subscriber Nodes.
//    Create a new Message object containing the content of the file added/updated, its path etc.
//    For each subscriber, insert a Message row referencing the Message (file created or updated) and the target node
//    For each subscriber, insert a Message row referencing the Message (directory child added or updated) and the target node (recursive for all parent folders)
//
// Service the Message queue. Each Message has a target Node ID.
// Load the Message, identify which code needs to execute to complete it. This will be a Translator or a File.
//
// We want decentralized logic attached to each Node. So for the above,
/*
struct Graph: Codable, Identifiable, FetchableRecord, PersistableRecord {
    enum Columns {
        static let name = Column(CodingKeys.name)
        static let pluginCreator = Column(CodingKeys.pluginCreator)
        static let kind = Column(CodingKeys.kind)
    }

    var id: ObjectID?
    var name: String
    var pluginCreator: String?
    var kind: GraphKind

    static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Graph", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("pluginCreator", .text)
                t.column("kind", .integer).notNull()
                t.column("parentGraphID", .integer)
            }
        }
    }
}
*/
