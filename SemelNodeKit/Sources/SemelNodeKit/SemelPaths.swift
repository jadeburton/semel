//
//  SemelPaths.swift
//  SemelNodeKit
//
//  Where the engine keeps what it persists. One root, absolute, independent of the
//  current directory: the graph database and the object store refer to each other (a
//  cache entry holds object hashes), so they have to move together, and a database
//  opened by a bare filename relative to wherever semel was launched from silently
//  started an empty graph against the shared store.

import Foundation

public enum SemelPaths {

    /// `~/Library/Application Support/semel`.
    public static var root: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("semel", isDirectory: true)
    }

    /// The content-addressed object store.
    public static var objectStore: URL {
        root.appendingPathComponent("objects", isDirectory: true)
    }

    /// The graph database. One per user, beside the store it refers into.
    public static var database: URL {
        root.appendingPathComponent("graph.sqlite", isDirectory: false)
    }
}
