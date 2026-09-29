//
//  PackageScan.swift
//  SemelSwiftTool
//
//  What `prepare` needs to know about a tree of Swift packages: which packages are there,
//  which of them depend on which by path, and what deployment versions they declare.
//  Read with `swift package dump-package`, like the converter does — SwiftPM evaluates the
//  manifest; nothing here parses Swift.

import Foundation

/// One package, as far as `prepare` cares.
public struct PackageSummary: Equatable {
    public let name: String
    /// The package folder, standardized so path comparisons are by value.
    public let folder: URL
    /// The folders of its `.package(path:)` dependencies, standardized the same way.
    public let pathDependencies: [URL]
    /// Declared deployment versions by SwiftPM platform name: `["ios": "18.0"]`.
    public let platforms: [String: String]
    /// The targets the converter compiles — regular and executable ones — so `prepare`
    /// can see which languages the tree holds (B-110).
    public let targets: [Target]

    /// One compiled target: its folder, at the path the manifest names or SwiftPM's
    /// `Sources/<name>`, and the scope its `sources:` and `exclude:` draw inside it — a
    /// target at its package's root (PLCrashReporter) holds far more than it compiles.
    public struct Target: Equatable {
        public let folder: URL
        /// Relative to `folder`; empty for the whole folder.
        public let sources: [String]
        /// Relative to `folder`.
        public let exclude: [String]

        public init(folder: URL, sources: [String] = [], exclude: [String] = []) {
            self.folder  = PackageSummary.normalized(folder)
            self.sources = sources
            self.exclude = exclude
        }
    }

    public init(name: String, folder: URL, pathDependencies: [URL], platforms: [String: String],
                targets: [Target] = []) {
        self.name             = name
        self.folder           = Self.normalized(folder)
        self.pathDependencies = pathDependencies.map(Self.normalized)
        self.platforms        = platforms
        self.targets          = targets
    }

    /// One spelling per folder, whatever the source: dump-package's absolute string and a
    /// URL built with `isDirectory: true` must compare equal.
    fileprivate static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}

public enum PackageScan {

    /// The folders under `folder` (itself included) holding a package manifest, sorted by
    /// path. A vendored dependency has a manifest too, and so does a checkout under
    /// `.build`, but neither is the tree's own package: `Dependencies` and every hidden
    /// folder are not entered.
    ///
    /// A manifest is a `Package.swift` that opens with the tools-version line SwiftPM
    /// requires of one. A file of that name deeper in a package is as likely a source —
    /// purchases-ios keeps its `Package` model in `Sources/Purchasing/Package.swift` —
    /// and `dump-package` on its folder fails the whole `prepare`; the name alone does
    /// not make a package.
    public static func manifestFolders(under folder: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []

        func visit(_ directory: URL) throws {
            if isManifest(directory.appendingPathComponent("Package.swift")) {
                found.append(directory.standardizedFileURL)
            }
            let children = try fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles])
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where child.lastPathComponent != Vendoring.dependenciesFolderName {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                try visit(child)
            }
        }

        try visit(folder)
        return found.sorted { $0.path < $1.path }
    }

    /// Whether the file at `url` is a package manifest: it exists, and its first line
    /// carries `swift-tools-version`, which SwiftPM requires of every manifest and which
    /// no Swift source has a reason to start with.
    static func isManifest(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256)) ?? Data()
        let firstLine = String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1).first ?? ""
        return firstLine.contains("swift-tools-version")
    }

    /// Reads one package's manifest with SwiftPM.
    public static func summary(ofPackageAt folder: URL) throws -> PackageSummary {
        let process = Process()
        let output  = Pipe()
        process.executableURL   = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments       = ["swift", "package", "dump-package", "--package-path", folder.path]
        process.standardOutput  = output
        process.standardError   = FileHandle.standardError
        try process.run()
        let json = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Vendoring.Failure(description: "swift package dump-package failed (exit \(process.terminationStatus)) for \(folder.path)")
        }
        return try summary(fromDumpPackageJSON: json, folder: folder)
    }

    /// The part of `dump-package`'s JSON that matters here. Tolerant of everything else in
    /// it: SwiftPM adds keys between releases, and a summary needs three.
    public static func summary(fromDumpPackageJSON json: Data, folder: URL) throws -> PackageSummary {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let name = object["name"] as? String else {
            throw Vendoring.Failure(description: "unreadable dump-package output for \(folder.path)")
        }

        var pathDependencies: [URL] = []
        for dependency in object["dependencies"] as? [[String: Any]] ?? [] {
            for local in dependency["fileSystem"] as? [[String: Any]] ?? [] {
                guard let path = local["path"] as? String else {
                    continue
                }
                // dump-package makes the path absolute; a manifest written relative
                // (`.package(path: "../Models")`) still comes back that way, but resolve
                // against the package folder in case it does not.
                pathDependencies.append(URL(fileURLWithPath: path, relativeTo: folder))
            }
        }

        var platforms: [String: String] = [:]
        for platform in object["platforms"] as? [[String: Any]] ?? [] {
            if let platformName = platform["platformName"] as? String,
               let version = platform["version"] as? String {
                platforms[platformName] = version
            }
        }

        // The targets the converter turns into compilers; a test, plugin, macro, system or
        // binary target is not one, as `isCompilable` says.
        var targets: [PackageSummary.Target] = []
        for target in object["targets"] as? [[String: Any]] ?? [] {
            guard let targetName = target["name"] as? String,
                  ["regular", "executable"].contains(target["type"] as? String ?? "regular") else {
                continue
            }
            let path = target["path"] as? String ?? "Sources/\(targetName)"
            targets.append(PackageSummary.Target(folder:  URL(fileURLWithPath: path, relativeTo: folder),
                                                 sources: target["sources"] as? [String] ?? [],
                                                 exclude: target["exclude"] as? [String] ?? []))
        }

        return PackageSummary(name: name, folder: folder, pathDependencies: pathDependencies,
                              platforms: platforms, targets: targets)
    }

    /// The packages nothing else in the set depends on by path: what a formula has to
    /// name, since everything else is reached through them. Sorted by folder path.
    public static func roots(of summaries: [PackageSummary]) -> [PackageSummary] {
        let dependedOn = Set(summaries.flatMap(\.pathDependencies).map(\.path))
        return summaries
            .filter { !dependedOn.contains($0.folder.path) }
            .sorted { $0.folder.path < $1.folder.path }
    }
}
