//
//  PortDef.swift
//  DatabaseModels
//
//  Created by Jade Burton on 11.06.26.
//

import Foundation
import GRDB

// Allows ports to be given a user-friendly string name. Every input Port has a
// corresponding input-expectation Port that describes what graph (formula) is needed to satisfy it
public struct PortDef: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let kind = Column(CodingKeys.kind)
    }

    public enum PortKind: UInt8, Codable {
        case regular = 1
        case inputExpectation = 2
    }

    public var id: ObjectID?
    public var name: String?
    public var kind: PortKind

    public init(id: ObjectID? = nil, name: String?, kind: PortKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    // NodeOutputValue uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "PortDef", options: .ifNotExists) { t in
                t.column("name", .text).notNull().indexed()
                t.column("kind", .integer).notNull()
            }
        }
    }
}

extension DatabaseLayer {

    // Select all NodeOutputValues associated with the given Node
    public func selectAllPorts(nodeID: ObjectID) throws -> [Port] {
        try dbQueue.read { db in
            try NodeOutputValue.filter(Port.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectNodeOutputValue(nodeID: ObjectID, portID: ObjectID) throws -> NodeOutputValue? {
        try dbQueue.read { db in
            try NodeOutputValue.filter(NodeOutputValue.Columns.nodeID == nodeID &&
                                       NodeOutputValue.Columns.portID == portID).fetchOne(db)
        }
    }

    public func insertOrReplaceNodeOutputValue(_ nodeOutputValue: NodeOutputValue) throws {
        try dbQueue.write { db in
            try nodeOutputValue.save(db)
        }
    }

    public func deleteNodeOutputValue(nodeID: ObjectID, portID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID &&
                        NodeOutputValue.Columns.portID == portID)
                .deleteAll(db) > 0
        }
    }

    public func deleteNodeOutputValues(nodeID: ObjectID) throws -> Int {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID)
                .deleteAll(db)
        }
    }
}

public extension NodeOutputValue {
    func description() -> String {
        "NodeOutputValue: nodeID=\(nodeID), port=\(port), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
