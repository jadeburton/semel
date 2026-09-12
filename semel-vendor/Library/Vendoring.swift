//
//  Vendoring.swift
//  SemelVendor
//
//  Semel is not a package manager, but it needs every file of every dependency inside its
//  input file system, found by one rule rather than per-dependency configuration. The rule
//  (docs/superpowers/specs/2026-09-12-semel-vendor-design.md): every source-control
//  dependency of every package in a graph lives at `<root>/Dependencies/<name>`, where
//  `<name>` is the repository's last path component minus `.git`. That is SwiftPM's own
//  checkout layout, so vendoring is: let SwiftPM resolve, then copy.

import Foundation

public enum Vendoring {

    public struct Copied: Equatable {
        public let name: String
        public let source: URL
        public let destination: URL
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The folder under a package root that holds its vendored dependencies.
    public static let dependenciesFolderName = "Dependencies"

    /// Resolves and copies: `swift package resolve` on `packageRoot`, then every checkout
    /// under `.build/checkouts` into `<packageRoot>/Dependencies/<name>`.
    public static func vendor(packageRoot: URL) throws -> [Copied] {
        try resolve(packageRoot: packageRoot)
        return try copyCheckouts(from: packageRoot.appendingPathComponent(".build/checkouts", isDirectory: true),
                                 into: packageRoot.appendingPathComponent(dependenciesFolderName, isDirectory: true))
    }

    /// SwiftPM does versions, `Package.resolved`, branches, registries and transitive
    /// resolution; nothing here re-implements any of it.
    public static func resolve(packageRoot: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "package", "resolve", "--package-path", packageRoot.path]
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "swift package resolve failed (exit \(process.terminationStatus)) for \(packageRoot.path)")
        }
    }

    /// Copies every directory in `checkouts` to `dependencies/<name>`, replacing whatever
    /// was there, and leaves out each checkout's `.git` and `.build`: neither is source,
    /// and a nested `.git` would make the copy look like a repository of its own.
    /// Returns what was copied, sorted by name.
    public static func copyCheckouts(from checkouts: URL, into dependencies: URL) throws -> [Copied] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: checkouts.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure(description: "no checkouts at \(checkouts.path) — did `swift package resolve` run?")
        }

        let names = try fileManager.contentsOfDirectory(atPath: checkouts.path)
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: checkouts.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()

        try fileManager.createDirectory(at: dependencies, withIntermediateDirectories: true)

        var copied: [Copied] = []
        for name in names {
            let source      = checkouts.appendingPathComponent(name, isDirectory: true)
            let destination = dependencies.appendingPathComponent(name, isDirectory: true)

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            for child in try fileManager.contentsOfDirectory(atPath: source.path).sorted()
            where child != ".git" && child != ".build" {
                try fileManager.copyItem(at: source.appendingPathComponent(child),
                                         to: destination.appendingPathComponent(child))
            }
            copied.append(Copied(name: name, source: source, destination: destination))
        }
        return copied
    }
}
