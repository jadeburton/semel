//
//  Vendoring.swift
//  SemelSwiftTool
//
//  Semel is not a package manager, but it needs every file of every dependency inside its
//  input file system, found by one rule rather than per-dependency configuration. The rule
//  (docs/superpowers/specs/2026-09-12-semel-swift-design.md): every source-control
//  dependency of every package in a graph lives at `<root>/Dependencies/<name>`, where
//  `<name>` is the repository's last path component minus `.git`. That is SwiftPM's own
//  checkout layout, so vendoring is: let SwiftPM resolve, then copy — and lock each copy
//  beside it, `<name>.semel-lock`, so a build can tell when it has moved (B-06).

import Foundation
import SemelNodeKit

public enum Vendoring {

    public struct Copied: Equatable {
        public let name: String
        public let source: URL
        public let destination: URL
        /// What the resolver chose for this checkout, when its resolved file says: recorded
        /// in the lock written beside the copy, never enforced.
        public let pin: Pin?

        public init(name: String, source: URL, destination: URL, pin: Pin? = nil) {
            self.name        = name
            self.source      = source
            self.destination = destination
            self.pin         = pin
        }
    }

    /// One entry of a `Package.resolved`: where a package came from and what was chosen.
    public struct Pin: Equatable {
        public let origin: String
        /// Nil for a branch or a revision pin.
        public let version: String?
        public let revision: String?

        public init(origin: String, version: String?, revision: String?) {
            self.origin   = origin
            self.version  = version
            self.revision = revision
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The folder under a package root that holds its vendored dependencies.
    public static let dependenciesFolderName = "Dependencies"

    /// Resolves and copies: `swift package resolve` on `packageRoot`, then every checkout
    /// under `.build/checkouts` into `<packageRoot>/Dependencies/<name>`.
    public static func vendor(packageRoot: URL) throws -> [Copied] {
        try vendor(packageRoots: [packageRoot],
                   into: packageRoot.appendingPathComponent(dependenciesFolderName, isDirectory: true))
    }

    /// Resolves each package and copies every checkout of each into one `dependencies`
    /// folder — the shape a formula that includes several packages with one build root
    /// needs (`SwiftFormulaConverter(path: <pkg>, root: <.>)`): their common closure is
    /// vendored once. A name two packages both resolve is copied by the later one; SwiftPM
    /// resolves them as separate graphs, so the versions can in principle differ, and the
    /// last copy wins as it would for a rerun.
    public static func vendor(packageRoots: [URL], into dependencies: URL) throws -> [Copied] {
        var copied: [Copied] = []
        for packageRoot in packageRoots {
            try resolve(packageRoot: packageRoot)
            copied += try copyCheckouts(from: packageRoot.appendingPathComponent(".build/checkouts", isDirectory: true),
                                        into: dependencies,
                                        pins: pins(inResolvedFileAt: packageRoot.appendingPathComponent("Package.resolved")))
        }
        return copied
    }

    /// An Xcode project declares its own package references beside its local packages'
    /// manifests, and only Xcode resolves the union: `xcodebuild -resolvePackageDependencies`
    /// clones every package the project reaches, transitively, into the folder it is
    /// given, under `checkouts/`, the same layout SwiftPM uses — so the copy step is the
    /// same. The clone folder is temporary; the copies are what the build reads.
    public static func vendor(project: URL, into dependencies: URL) throws -> [Copied] {
        let clones = FileManager.default.temporaryDirectory
            .appendingPathComponent("semel-swift-clones-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: clones) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild", "-resolvePackageDependencies", "-project", project.path,
                             "-clonedSourcePackagesDirPath", clones.path]
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "xcodebuild -resolvePackageDependencies failed (exit \(process.terminationStatus)) for \(project.path)")
        }
        // Xcode keeps the project's resolved file in the workspace inside the project.
        let resolvedFile = project.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        return try copyCheckouts(from: clones.appendingPathComponent("checkouts", isDirectory: true), into: dependencies,
                                 pins: pins(inResolvedFileAt: resolvedFile))
    }

    /// The pins of a `Package.resolved`, by the folder each package is checked out under —
    /// the name a checkout has and a copy keeps. Empty when there is no such file, or it is
    /// in a shape older than `pins` at its top: what a pin says is recorded, not needed.
    public static func pins(inResolvedFileAt file: URL) -> [String: Pin] {
        struct ResolvedFile: Decodable {
            struct Entry: Decodable {
                struct State: Decodable {
                    let version: String?
                    let revision: String?
                }
                let location: String
                let state: State
            }
            let pins: [Entry]
        }
        guard let data = try? Data(contentsOf: file),
              let resolved = try? JSONDecoder().decode(ResolvedFile.self, from: data) else {
            return [:]
        }
        var pins: [String: Pin] = [:]
        for entry in resolved.pins {
            guard let name = DependencyLock.folderName(forRepositoryURL: entry.location) else {
                continue
            }
            pins[name] = Pin(origin: entry.location, version: entry.state.version, revision: entry.state.revision)
        }
        return pins
    }

    /// Writes the lock beside a copy (B-06): its folder's content root as the engine will
    /// fold the pushed copy, and what its pin says. Replaces a lock already there, because
    /// the copy it described was replaced too. Returns the lock file.
    @discardableResult
    public static func writeLock(for copied: Copied) throws -> URL {
        let lock = DependencyLock(contentRoot: try FolderContentRoot.root(ofFolderAt: copied.destination),
                                  fold:        FolderContentRoot.formatTag,
                                  version:     copied.pin?.version,
                                  revision:    copied.pin?.revision,
                                  origin:      copied.pin?.origin)
        let file = DependencyLock.lockFile(forDependencyAt: copied.destination)
        try lock.text.write(to: file, atomically: true, encoding: .utf8)
        return file
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
    /// Returns what was copied, sorted by name, each with its pin from `pins` when there is one.
    public static func copyCheckouts(from checkouts: URL, into dependencies: URL,
                                     pins: [String: Pin] = [:]) throws -> [Copied] {
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
            copied.append(Copied(name: name, source: source, destination: destination, pin: pins[name]))
        }
        return copied
    }
}
