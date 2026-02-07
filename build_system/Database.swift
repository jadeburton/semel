//
//  Database.swift
//  build_system
//
//  Created by Jade Burton on 06.02.26.
//

import GRDB
import DatabaseModels

final class Database {
    let dbQueue: DatabaseQueue

    enum DatabaseError: Error {
        case nodeNotFound
        case nodePortNotFound
        case wireNotFound
        case dataObjectNotFound
    }

    init(filePath: String) throws {
        dbQueue = try DatabaseQueue(path: filePath)

        try Node.createTable(dbQueue: dbQueue)
        try Wire.createTable(dbQueue: dbQueue)
        try Message.createTable(dbQueue: dbQueue)
        try DataObject.createTable(dbQueue: dbQueue)
        try NodeOutputValue.createTable(dbQueue: dbQueue)
    }
}
