// PackageClangTarget.swift
// SemelSwift
//
// What a package target's folder tree says about building it with clang (B-54, B-55).
//
// A manifest says nothing about a target's language; SwiftPM decides it from the files:
// a target with any Swift source is a Swift target, and one with C-family sources and no
// Swift is a C target. This file is that reading, over the folder tree the converter
// walked, and what the formula needs of it — which files the per-file for-each takes,
// which it leaves out, and where the public headers are.

import Foundation
import SemelNodeKit

struct PackageClangTarget: Equatable {

    /// What the manifest says about a C target's files: its `sources:` and `exclude:`
    /// lists, its `publicHeadersPath` and its unconditional `.headerSearchPath` settings,
    /// each relative to the target's folder.
    struct Rules: Equatable {
        let sources: [String]
        let exclude: [String]
        /// nil when the manifest names none, which is SwiftPM's `include`.
        let publicHeadersPath: String?
        let headerSearchPaths: [String]

        init(sources: [String] = [], exclude: [String] = [], publicHeadersPath: String? = nil,
             headerSearchPaths: [String] = []) {
            self.sources           = sources
            self.exclude           = exclude
            self.publicHeadersPath = publicHeadersPath
            self.headerSearchPaths = headerSearchPaths
        }
    }

    static let cFamilyExtensions: Set<String> = ["c", "m", "mm", "cpp", "cc", "cxx"]

    /// SwiftPM's public-headers folder when the manifest names none.
    static let defaultPublicHeadersPath = "include"

    /// The for-each items that pick the target's sources, relative to its folder and
    /// sorted: `**/*.c` for each extension found under a source folder — the whole target
    /// when `sources:` lists nothing — and a file `sources:` lists by name as written.
    let sourcePatterns: [String]

    /// The for-each's `except` items, relative to the target's folder and sorted: `Tests/**`
    /// for an excluded folder holding a source the patterns would take, and the path for an
    /// excluded source file. An exclusion nothing matches — a `CMakeLists.txt`, a `.re`
    /// grammar — is left out, being noise in the formula.
    let excludedPatterns: [String]

    /// The public-headers folder relative to the target's folder, "" when it is the folder
    /// itself (`publicHeadersPath: "."`); nil when the folder does not exist.
    let publicHeadersPath: String?

    /// The `.headerSearchPath` folders relative to the target's folder, in manifest order,
    /// each once: one more header folder for the target's own preprocessor, which is what
    /// SwiftPM's `-I` for it is. A path naming no folder the walk found is left out, as
    /// clang passes over a search path that is not there.
    let headerSearchPaths: [String]

    /// nil for a Swift target: one with a `.swift` file anywhere in scope, or with no
    /// C-family source at all.
    ///
    /// The whole tree, not the folder's top level. SwiftPM reads the whole tree, and a
    /// reading of the top level alone gets both directions wrong: a C target whose
    /// sources all sit in subfolders was taken for Swift and handed to `swiftc` with
    /// nothing to compile, and a Swift target whose top level held one stray `.c` beside
    /// only folders was taken for C.
    ///
    /// `manifests` is every folder the converter walked, keyed by full path. The walk does
    /// not enter a hidden folder or a resource whole (an `.xcassets`), and neither does a
    /// formula's `**`, so the two agree on what the target holds.
    init?(targetFolder: String, rules: Rules, manifests: [String: FolderManifest]) {
        guard manifests[targetFolder] != nil else {
            return nil
        }

        /// Every pinned file under `relative`, as a path relative to the target folder,
        /// excluded or not — the caller decides.
        func files(under relative: String) -> [String] {
            let folderPath = relative.isEmpty ? targetFolder : "\(targetFolder)/\(relative)"
            guard let manifest = manifests[folderPath] else {
                return []
            }
            var found: [String] = []
            for entry in manifest.entries.sorted(by: { $0.name < $1.name }) where entry.isPinned {
                let entryPath = relative.isEmpty ? entry.name : "\(relative)/\(entry.name)"
                if !entry.isFolder {
                    found.append(entryPath)
                    continue
                }
                if PackageResources.isWalked(folderName: entry.name) {
                    found.append(contentsOf: files(under: entryPath))
                }
            }
            return found
        }

        func isExcluded(_ path: String) -> Bool {
            rules.exclude.contains { PackageResources.isAtOrUnder(path, $0) }
        }

        func isInScope(_ path: String) -> Bool {
            rules.sources.isEmpty || rules.sources.contains { PackageResources.isAtOrUnder(path, $0) }
        }

        let everyFile = files(under: "")
        let sourceFiles = everyFile.filter { isInScope($0) && !isExcluded($0) }
        guard !sourceFiles.contains(where: { Self.fileExtension($0).lowercased() == "swift" }) else {
            return nil
        }

        // A source folder — the target, or a folder `sources:` lists — takes one pattern per
        // extension found under it; a file `sources:` lists is taken by name. A folder
        // listed inside another listed folder adds nothing and would name its files twice.
        let listedFolders = rules.sources.map(Self.normalized).filter { manifests[Self.joined(targetFolder, $0)] != nil }
        let sourceFolders = rules.sources.isEmpty
            ? [""]
            : listedFolders.filter { folder in !listedFolders.contains { $0 != folder && PackageResources.isAtOrUnder(folder, $0) } }
        var patterns = Set<String>()
        for folder in sourceFolders {
            for file in sourceFiles where folder.isEmpty || PackageResources.isAtOrUnder(file, folder) {
                let fileExtension = Self.fileExtension(file)
                guard Self.cFamilyExtensions.contains(fileExtension.lowercased()) else { continue }
                patterns.insert(Self.joined(folder, "\(WildcardPath.anyFolders)/*.\(fileExtension)"))
            }
        }
        for listed in rules.sources.map(Self.normalized) where !listedFolders.contains(listed) {
            guard sourceFiles.contains(listed), Self.cFamilyExtensions.contains(Self.fileExtension(listed).lowercased()) else {
                continue
            }
            patterns.insert(listed)
        }
        guard !patterns.isEmpty else {
            return nil
        }

        // An exclusion matters when it takes out a file a pattern would take: a C-family
        // file in scope.
        let excludedSources = everyFile.filter { file in
            isInScope(file) && isExcluded(file) && Self.cFamilyExtensions.contains(Self.fileExtension(file).lowercased())
        }
        var exclusions = Set<String>()
        for excluded in rules.exclude.map(Self.normalized) {
            guard excludedSources.contains(where: { PackageResources.isAtOrUnder($0, excluded) }) else { continue }
            let isFolder = manifests[Self.joined(targetFolder, excluded)] != nil
            exclusions.insert(isFolder ? Self.joined(excluded, WildcardPath.anyFolders) : excluded)
        }

        let headers = Self.normalized(rules.publicHeadersPath ?? Self.defaultPublicHeadersPath)

        sourcePatterns    = patterns.sorted()
        excludedPatterns  = exclusions.sorted()
        publicHeadersPath = manifests[Self.joined(targetFolder, headers)] != nil ? headers : nil

        var searchPaths: [String] = []
        for searchPath in rules.headerSearchPaths.map(Self.normalized)
        where manifests[Self.joined(targetFolder, searchPath)] != nil && !searchPaths.contains(searchPath) {
            searchPaths.append(searchPath)
        }
        headerSearchPaths = searchPaths
    }

    /// A manifest path as the walk spells it: no `./` in front, no `/` behind, and "" for
    /// the folder itself.
    static func normalized(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    /// `relative` under `folder`, where either may be "".
    static func joined(_ folder: String, _ relative: String) -> String {
        guard !relative.isEmpty else { return folder }
        guard !folder.isEmpty else { return relative }
        return "\(folder)/\(relative)"
    }

    /// The extension as written: a pattern is matched case by case, so `.C` files want a
    /// `*.C` pattern of their own.
    private static func fileExtension(_ path: String) -> String {
        (path as NSString).pathExtension
    }
}
