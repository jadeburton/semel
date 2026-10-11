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

    /// `~/Library/Application Support/semel`, or `SEMEL_HOME` when set. The override exists
    /// so a server started by a test has a root of its own; nothing else should set it.
    public static var root: URL {
        if let home = ProcessInfo.processInfo.environment["SEMEL_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("semel", isDirectory: true)
    }

    /// The content-addressed object store.
    public static var objectStore: URL {
        root.appendingPathComponent("objects", isDirectory: true)
    }

    /// The graph database. One per user, beside the store it refers into.
    public static var database: URL {
        root.appendingPathComponent("graph.sqlite", isDirectory: false)
    }

    /// The sandbox folders a tool that leaves a daemon in its working directory runs in
    /// (`ReusedSandboxFolders`, B-152). Under the user's own Semel folder whatever
    /// `SEMEL_HOME` says, deliberately: a test's home is removed when the test ends, and a
    /// daemon whose folder went with it fails every client on the machine after it. One set
    /// per user, as the daemon is.
    public static var reusedSandboxFolders: URL {
        URL.applicationSupportDirectory.appendingPathComponent("semel/tool-sandboxes", isDirectory: true)
    }

    /// Where `semelserv` listens and `semel` connects, or `SEMEL_SOCKET` when set. A
    /// Unix-domain socket is a name in the file system that the kernel routes connections
    /// through; keeping it under the user's own root is what stands in for authentication.
    public static var serverSocket: URL {
        if let socket = ProcessInfo.processInfo.environment["SEMEL_SOCKET"], !socket.isEmpty {
            return URL(fileURLWithPath: socket, isDirectory: false)
        }
        return root.appendingPathComponent("semelserv.sock", isDirectory: false)
    }
}
