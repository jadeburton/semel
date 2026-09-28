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

    /// `.S`, preprocessed, and `.s`, as it is: SwiftPM compiles both in a C target
    /// (PLCrashReporter's `PLCrashAsyncThread_current.S`, BoringSSL's generated `.S`), and
    /// counts them among its sources (B-55). Lowercased, as the extensions above are.
    static let assemblyExtensions: Set<String> = ["s"]

    /// Every extension a C target compiles.
    static let sourceExtensions = cFamilyExtensions.union(assemblyExtensions)

    /// The extensions compiled as C++ or Objective-C++, whose objects need the C++ runtime
    /// at link; `.C` is C++ too, by case, as the compiler reads it.
    static let cxxExtensions: Set<String> = ["mm", "cpp", "cc", "cxx"]

    /// Objective-C and Objective-C++: a target holding one is built with ARC and modules.
    static let objectiveCExtensions: Set<String> = ["m", "mm"]

    /// What a header is, for the headers a Swift importer is given. `.inc` and `.def` are
    /// included by headers as often as by sources.
    static let headerExtensions: Set<String> = ["h", "hh", "hpp", "hxx", "inc", "def"]

    /// The name clang gives a module map in a public-headers folder.
    static let moduleMapFileName = "module.modulemap"

    /// How Swift imports the target: through the module map its public-headers folder
    /// holds, or through the one SwiftPM writes when it holds none (B-55).
    enum ModuleMap: Equatable {
        /// The folder's own `module.modulemap`.
        case provided
        /// `umbrella header`, relative to the public-headers folder: `Kit.h`, or `Kit/Kit.h`.
        case umbrellaHeader(String)
        /// `umbrella`, the public-headers folder itself.
        case umbrellaDirectory
    }

    /// SwiftPM's public-headers folder when the manifest names none.
    static let defaultPublicHeadersPath = "include"

    /// The for-each items that pick the target's sources, relative to its folder and
    /// sorted: `**/*.c` for each extension found under a source folder — the whole target
    /// when `sources:` lists nothing — and a file `sources:` lists by name as written.
    let sourcePatterns: [String]

    /// The same for `.s` files, which have no preprocessing phase: the compiler takes them
    /// as they are, so they are a for-each of their own with no preprocessor (B-55).
    let assemblyPatterns: [String]

    /// Whether any source is C++ or Objective-C++, so a product linking the target's
    /// objects needs the C++ runtime (B-55).
    let compilesCxx: Bool

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

    /// Whether a source the patterns take is Objective-C or Objective-C++: SwiftPM builds
    /// such a target with ARC and clang modules, so its headers may `@import Foundation;`
    /// (B-77).
    let hasObjectiveC: Bool

    /// Every header under the target folder that `exclude:` leaves, relative to it and
    /// sorted, and the public-headers folder's own module map when it has one: what a Swift
    /// target importing this one is given, at the paths they have here. The whole target's,
    /// not the public folder's alone: a public header may reach back into the target —
    /// NetNewsWire's `include/RSDatabaseObjC.h` is `#import "../FMDatabase.h"` — and one
    /// nested below the public folder is as much the module's. `sources:` does not narrow
    /// it, as a public-headers folder is rarely among the sources; `exclude:` does, so an
    /// excluded module map (Zip's `minizip/module`) cannot declare the module a second time.
    let headerFiles: [String]

    /// How Swift imports the target, by SwiftPM's rule over the public-headers folder's
    /// listing; nil when it has no such folder, and so no module Swift can import.
    let moduleMap: ModuleMap?

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
    ///
    /// `moduleName` is the target's c99 name, which a module map SwiftPM writes is named
    /// for and its umbrella header is looked for by.
    init?(targetFolder: String, moduleName: String, rules: Rules, manifests: [String: FolderManifest]) {
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
        var takenExtensions = Set<String>()
        for folder in sourceFolders {
            for file in sourceFiles where folder.isEmpty || PackageResources.isAtOrUnder(file, folder) {
                let fileExtension = Self.fileExtension(file)
                guard Self.sourceExtensions.contains(fileExtension.lowercased()) else { continue }
                patterns.insert(Self.joined(folder, "\(WildcardPath.anyFolders)/*.\(fileExtension)"))
                takenExtensions.insert(fileExtension)
            }
        }
        for listed in rules.sources.map(Self.normalized) where !listedFolders.contains(listed) {
            guard sourceFiles.contains(listed), Self.sourceExtensions.contains(Self.fileExtension(listed).lowercased()) else {
                continue
            }
            patterns.insert(listed)
            takenExtensions.insert(Self.fileExtension(listed))
        }
        guard !patterns.isEmpty else {
            return nil
        }

        // An exclusion matters when it takes out a file a pattern would take: a source file
        // in scope.
        let excludedSources = everyFile.filter { file in
            isInScope(file) && isExcluded(file) && Self.sourceExtensions.contains(Self.fileExtension(file).lowercased())
        }
        var exclusions = Set<String>()
        for excluded in rules.exclude.map(Self.normalized) {
            guard excludedSources.contains(where: { PackageResources.isAtOrUnder($0, excluded) }) else { continue }
            let isFolder = manifests[Self.joined(targetFolder, excluded)] != nil
            exclusions.insert(isFolder ? Self.joined(excluded, WildcardPath.anyFolders) : excluded)
        }

        let headers = Self.normalized(rules.publicHeadersPath ?? Self.defaultPublicHeadersPath)
        let publicFolder = Self.joined(targetFolder, headers)
        let hasPublicFolder = manifests[publicFolder] != nil

        let isUnpreprocessedAssembly = { (pattern: String) in Self.fileExtension(pattern) == "s" }
        let sortedPatterns = patterns.sorted()
        sourcePatterns    = sortedPatterns.filter { !isUnpreprocessedAssembly($0) }
        assemblyPatterns  = sortedPatterns.filter(isUnpreprocessedAssembly)
        compilesCxx       = takenExtensions.contains { $0 == "C" || Self.cxxExtensions.contains($0.lowercased()) }
        excludedPatterns  = exclusions.sorted()
        publicHeadersPath = hasPublicFolder ? headers : nil
        hasObjectiveC     = patterns.contains { Self.objectiveCExtensions.contains(Self.fileExtension($0).lowercased()) }
        let map = hasPublicFolder
            ? Self.moduleMap(moduleName: moduleName, publicHeadersFolder: publicFolder, manifests: manifests)
            : nil
        moduleMap = map

        let publicModuleMap = Self.joined(headers, Self.moduleMapFileName)
        headerFiles = everyFile.filter { file in
            guard !isExcluded(file) else {
                return false
            }
            return Self.headerExtensions.contains(Self.fileExtension(file).lowercased())
                || (map == .provided && file == publicModuleMap)
        }.sorted()

        var searchPaths: [String] = []
        for searchPath in rules.headerSearchPaths.map(Self.normalized)
        where manifests[Self.joined(targetFolder, searchPath)] != nil && !searchPaths.contains(searchPath) {
            searchPaths.append(searchPath)
        }
        headerSearchPaths = searchPaths
    }

    /// SwiftPM's rule (`ModuleMapGenerator.determineModuleMapType`), over the public-headers
    /// folder's own listing: its `module.modulemap` when it has one; else `<Module>.h` beside
    /// no folder, as the umbrella header; else `<Module>/<Module>.h` in the one folder there
    /// with no header beside it; else the folder as an umbrella directory. SwiftPM refuses a
    /// package where an umbrella header has folders beside it, or its folder has company;
    /// such a target gets no map here, as it would get no module there. Hidden entries are
    /// not counted, as the walk does not enter them.
    static func moduleMap(moduleName: String, publicHeadersFolder: String,
                          manifests: [String: FolderManifest]) -> ModuleMap? {
        func listing(_ folder: String) -> (files: Set<String>, folders: [String]) {
            let entries = (manifests[folder]?.entries ?? []).filter { $0.isPinned && !$0.name.hasPrefix(".") }
            return (Set(entries.filter { !$0.isFolder }.map(\.name)), entries.filter(\.isFolder).map(\.name))
        }
        let (files, folders) = listing(publicHeadersFolder)
        let umbrellaName = "\(moduleName).h"

        if files.contains(moduleMapFileName) {
            return .provided
        }
        if files.contains(umbrellaName) {
            return folders.isEmpty ? .umbrellaHeader(umbrellaName) : nil
        }
        if listing(joined(publicHeadersFolder, moduleName)).files.contains(umbrellaName) {
            let headersBeside = files.contains { fileExtension($0).lowercased() == "h" }
            return folders.count == 1 && !headersBeside ? .umbrellaHeader("\(moduleName)/\(umbrellaName)") : nil
        }
        return .umbrellaDirectory
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
