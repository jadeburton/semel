//
//  FileSystem.swift
//  build_system
//
//  Created by Jade Burton on 07.02.26.
//



/*
final class FileSystem {
    private let database: Database

    init (database: Database) {
        self.database = database
    }

    func importAll(basePath: String) throws {
        // There is only one file system, but it may have many root directories that map to different locations outside
//        let folderID = try! database.insertOrGetExistingGraph(name: "fs", kind: .folder, pluginCreator: nil)

        var folderNodeID = try database.selectRootFolder(name: "input")?.id

        if folderNodeID == nil {
            folderNodeID = try database.insertNode(.init(content: .folder(name: "input", parentFolderID: nil/*, kind: .folder*/)))
        }

        importAll(basePath: basePath, folderNodeID: folderNodeID!)
    }

    private func importAll(basePath: String, folderNodeID: ObjectID) {
        // TODO: transactional
        recurseAllFilesBeneathDirectory(rootDirectoryPath: basePath,
                                        createRootFolder: { name in

            let existing = try? database.selectFileInFolder(folderNodeID: folderNodeID, name: name)

            if let existing {
                return existing.id!
            }

            return try! database.insertNode(.init(content: .folder(name: name, parentFolderID: folderNodeID/*, kind: .folder*/)))

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

            let dataObjectHash = content.intern()
            let nodeID = try! database.insertNode(.init(content: .staticFile(name: name, parentFolderID: insideFolderID/*, kind: .staticFile*/)))

            _ = try! database.insertOrReplacePort(.init(nodeID: nodeID, port: 0, dataObjectHash: dataObjectHash))

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
