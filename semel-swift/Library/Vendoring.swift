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
//  beside it, `<name>.semel-lock`, so a build can tell when it has moved (B-06). A copy
//  whose lock already says what resolution chose, and whose folder still folds to what the
//  lock says, is left as it is (B-138): a rerun of `prepare` moves only what moved.

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
        /// Whether the checkout was copied, and why, or the copy already there was left.
        public let change: Change

        public init(name: String, source: URL, destination: URL, pin: Pin? = nil, change: Change = .copied(.absent)) {
            self.name        = name
            self.source      = source
            self.destination = destination
            self.pin         = pin
            self.change      = change
        }
    }

    /// What vendoring did with one checkout (B-138).
    public enum Change: Equatable {
        /// The copy there is what copying would make again, and its lock says so. Neither
        /// is touched, so its content root does not move and nothing downstream rebuilds.
        case unchanged
        case copied(CopyReason)
    }

    /// Why a checkout was copied over whatever was under its name. Every case past
    /// `lockUnreadable` carries the lock that was there, so a report can say what moved
    /// from what.
    public enum CopyReason: Equatable {
        /// Nothing was vendored under the name.
        case absent
        /// A copy with no lock beside it: nothing says what it is.
        case lockMissing
        /// A lock that does not parse, and so cannot say what the copy is.
        case lockUnreadable(DependencyLockError)
        /// The lock's root was taken under another fold than this `prepare` takes one under,
        /// so the two roots cannot be compared.
        case foldChanged(DependencyLock)
        /// Resolution chose another version, revision or origin than the lock records.
        case pinMoved(DependencyLock)
        /// The checksums the copy's manifest names for its binary targets are not the ones
        /// the lock records.
        case artifactsDiffer(DependencyLock)
        /// The dot-named files the copy's manifest declares as resources are not the ones
        /// the lock names (B-143).
        case hiddenFilesDiffer(DependencyLock)
        /// The copy folds to another root than its lock's: it was changed after it was
        /// vendored, and `prepare` is where a person asks for it to be made right.
        case contentDiffers(DependencyLock)
    }

    /// What a lock records from the manifest in a vendored package's folder: the `checksum:`
    /// of each binary target it declares, by target, its `artifacts` line; and the dot-named
    /// files its targets declare as resources, its `hidden` lines (B-143).
    public struct ManifestFacts: Equatable {
        public var artifacts: [String: String]
        /// Relative to the package's folder, sorted.
        public var hiddenFiles: [String]

        public init(artifacts: [String: String] = [:], hiddenFiles: [String] = []) {
            self.artifacts   = artifacts
            self.hiddenFiles = hiddenFiles.sorted()
        }
    }

    /// Reads a vendored package's `ManifestFacts`. Handed in, because reading a manifest is
    /// running SwiftPM, which `Preparation` does for every vendored package anyway and can
    /// do once for both.
    public typealias ReadManifestFacts = (URL) throws -> ManifestFacts

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

    /// Resolves each package and copies every checkout of each into one `dependencies`
    /// folder — the shape a formula that includes several packages with one build root
    /// needs (`SwiftFormulaConverter(path: <pkg>, root: <.>)`): their common closure is
    /// vendored once. A name two packages both resolve is copied by the later one; SwiftPM
    /// resolves them as separate graphs, so the versions can in principle differ, and the
    /// last copy wins as it would for a rerun.
    public static func vendor(packageRoots: [URL], into dependencies: URL,
                              manifestFacts: ReadManifestFacts) throws -> [Copied] {
        var copied: [Copied] = []
        for packageRoot in packageRoots {
            try resolve(packageRoot: packageRoot)
            let artifacts = packageRoot.appendingPathComponent(".build/artifacts", isDirectory: true)
            copied += try copyCheckouts(from: packageRoot.appendingPathComponent(".build/checkouts", isDirectory: true),
                                        into: dependencies,
                                        pins: pins(inResolvedFileAt: packageRoot.appendingPathComponent("Package.resolved")),
                                        artifacts: artifacts,
                                        manifestFacts: manifestFacts)
            // The root's own binary targets, which SwiftPM downloads beside its dependencies'.
            try copyArtifacts(from: artifacts, identity: packageRoot.lastPathComponent, into: packageRoot)
        }
        return copied
    }

    /// An Xcode project declares its own package references beside its local packages'
    /// manifests, and only Xcode resolves the union: `xcodebuild -resolvePackageDependencies`
    /// clones every package the project reaches, transitively, into the folder it is
    /// given, under `checkouts/`, the same layout SwiftPM uses — so the copy step is the
    /// same. The clone folder is temporary; the copies are what the build reads.
    public static func vendor(project: URL, into dependencies: URL, manifestFacts: ReadManifestFacts) throws -> [Copied] {
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
                                 pins: pins(inResolvedFileAt: resolvedFile),
                                 artifacts: clones.appendingPathComponent("artifacts", isDirectory: true),
                                 manifestFacts: manifestFacts)
    }

    /// The folder in a package a binary target's artifact is vendored into, one per target.
    public static let artifactsFolderName = DependencyLock.artifactsFolderName

    /// Copies what SwiftPM downloaded for the package `identity` — every
    /// `<artifacts>/<identity>/<Target>/`, the `.xcframework` it extracted from the zip a
    /// binary target's `url:` names, after checking the zip against the manifest's
    /// `checksum:` — into `<package>/semel-artifacts/<Target>/`, replacing what was there
    /// (B-77), and keeps only the `.xcframework` of it (`keepOnlyTheXCFramework`). Nothing
    /// is downloaded here: resolution already did it, and a build never does. The identity
    /// is SwiftPM's, the lowercased repository or folder name.
    public static func copyArtifacts(from artifacts: URL, identity: String, into package: URL) throws {
        let fileManager = FileManager.default
        guard let identities = try? fileManager.contentsOfDirectory(atPath: artifacts.path),
              let folder = identities.first(where: { $0.lowercased() == identity.lowercased() }) else {
            return
        }
        let source = artifacts.appendingPathComponent(folder, isDirectory: true)
        for target in try fileManager.contentsOfDirectory(atPath: source.path).sorted() where !target.hasPrefix(".") {
            var isDirectory: ObjCBool = false
            let targetSource = source.appendingPathComponent(target, isDirectory: true)
            guard fileManager.fileExists(atPath: targetSource.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !(try fileManager.contentsOfDirectory(atPath: targetSource.path)).isEmpty else {
                continue
            }
            let destination = package.appendingPathComponent(artifactsFolderName, isDirectory: true)
                                     .appendingPathComponent(target, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: targetSource, to: destination)
            try keepOnlyTheXCFramework(in: destination, target: target)
        }
    }

    /// Leaves in a binary target's folder under `semel-artifacts` only the `.xcframework`
    /// the build reads, `<Target>.xcframework` or, when the zip names it otherwise, the
    /// first by name — the one the converter takes (B-77). A zip holds what its vendor put
    /// beside the framework: Sparkle's its `bin/` of tools, the changelog, the licence, a
    /// sample appcast, which would be pushed and locked with it and read by nothing. A
    /// folder with no `.xcframework` in it is left as it is, so the converter can say what
    /// is there instead (an `.artifactbundle`, B-133).
    public static func keepOnlyTheXCFramework(in folder: URL, target: String) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: folder.path).sorted()
        let xcframeworks = contents.filter { $0.hasSuffix(".xcframework") }
        guard let kept = xcframeworks.first(where: { $0 == "\(target).xcframework" }) ?? xcframeworks.first else {
            return
        }
        for name in contents where name != kept {
            try fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Unzips a binary target's `path:` zip into `<package>/semel-artifacts/<Target>/`,
    /// replacing what was there, as SwiftPM extracts one before a build (B-77), and keeps
    /// only the `.xcframework` of it. `ditto`, because it keeps what a framework is made
    /// of — its links and its modes — as Finder's archiver wrote them.
    public static func unzipArtifact(_ zip: URL, target: String, into package: URL) throws {
        let destination = package.appendingPathComponent(artifactsFolderName, isDirectory: true)
                                 .appendingPathComponent(target, isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        process.standardOutput = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "could not unzip \(zip.path) for binary target \(target) (ditto exit \(process.terminationStatus))")
        }
        try keepOnlyTheXCFramework(in: destination, target: target)
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
    /// fold the pushed copy — its `semel-artifacts` included — what its pin says, and the
    /// checksum of each binary target's download, by target. Replaces a lock already
    /// there, because the copy it described was replaced too. Returns the lock file.
    @discardableResult
    public static func writeLock(for copied: Copied, facts: ManifestFacts = ManifestFacts()) throws -> URL {
        let lock = DependencyLock(contentRoot: try FolderContentRoot.root(ofFolderAt: copied.destination,
                                                                          hiddenFiles: facts.hiddenFiles),
                                  fold:        FolderContentRoot.formatTag,
                                  version:     copied.pin?.version,
                                  revision:    copied.pin?.revision,
                                  origin:      copied.pin?.origin,
                                  artifacts:   facts.artifacts,
                                  hiddenFiles: facts.hiddenFiles)
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
    /// and a nested `.git` would make the copy look like a repository of its own. The
    /// binary artifacts resolution downloaded for a checkout, found in `artifacts` under its
    /// identity, go into the copy's `semel-artifacts` (B-77). A copy that `reasonToCopy`
    /// finds already right is left, its lock with it (B-138).
    /// Returns every checkout, sorted by name, each with its pin from `pins` when there is
    /// one and what was done with it.
    public static func copyCheckouts(from checkouts: URL, into dependencies: URL,
                                     pins: [String: Pin] = [:], artifacts: URL? = nil,
                                     manifestFacts: ReadManifestFacts) throws -> [Copied] {
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

            guard let reason = try reasonToCopy(to: destination, pin: pins[name], manifestFacts: manifestFacts) else {
                copied.append(Copied(name: name, source: source, destination: destination, pin: pins[name], change: .unchanged))
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            for child in try fileManager.contentsOfDirectory(atPath: source.path).sorted()
            where child != ".git" && child != ".build" {
                try fileManager.copyItem(at: source.appendingPathComponent(child),
                                         to: destination.appendingPathComponent(child))
            }
            if let artifacts {
                try copyArtifacts(from: artifacts, identity: name, into: destination)
            }
            copied.append(Copied(name: name, source: source, destination: destination, pin: pins[name],
                                 change: .copied(reason)))
        }
        return copied
    }

    /// Why the copy at `destination` has to be made again for `pin`, or nil when the one
    /// there is what copying would make: its lock records the pin, was taken under this
    /// fold and records the checksums its manifest names, and the folder still folds to the
    /// lock's root. Cheapest first — the pin is a comparison, the checksums are a manifest
    /// read `Preparation` keeps for later, and the root is a walk of every file — so a
    /// rerun after a pin moved folds only the copies whose pins did not.
    ///
    /// The pin compared is the whole of what the lock records of it: a version that stays
    /// while its revision moves is a retagged release, and an origin that moves is another
    /// repository under the same name, and either is a different checkout.
    static func reasonToCopy(to destination: URL, pin: Pin?, manifestFacts: ReadManifestFacts) throws -> CopyReason? {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .absent
        }
        let lockFile = DependencyLock.lockFile(forDependencyAt: destination)
        guard let lockData = FileManager.default.contents(atPath: lockFile.path) else {
            return .lockMissing
        }
        let lock: DependencyLock
        do {
            lock = try DependencyLock.parse(String(decoding: lockData, as: UTF8.self))
        } catch let error as DependencyLockError {
            return .lockUnreadable(error)
        }
        guard lock.fold == FolderContentRoot.formatTag else {
            return .foldChanged(lock)
        }
        guard lock.version == pin?.version, lock.revision == pin?.revision, lock.origin == pin?.origin else {
            return .pinMoved(lock)
        }
        let facts = try manifestFacts(destination)
        guard facts.artifacts == lock.artifacts else {
            return .artifactsDiffer(lock)
        }
        guard facts.hiddenFiles == lock.hiddenFiles else {
            return .hiddenFilesDiffer(lock)
        }
        guard try FolderContentRoot.root(ofFolderAt: destination, hiddenFiles: lock.hiddenFiles) == lock.contentRoot else {
            return .contentDiffers(lock)
        }
        return nil
    }
}
