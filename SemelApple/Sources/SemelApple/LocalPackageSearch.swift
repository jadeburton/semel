//
//  LocalPackageSearch.swift
//  SemelApple
//
//  Where Xcode finds a project's local packages. The project file declares some — a folder
//  wrapper among its file references, an `XCLocalSwiftPackageReference` with a path — and
//  for the rest names no package at all: a folder directly in a synchronized folder that
//  holds a `Package.swift` is a local package to Xcode, found by looking, and a product
//  dependency with no package is found by name among every local package there is.
//  NetNewsWire keeps its seventeen packages that way, in the synchronized `Modules` folder
//  that no target owns. The looking is over folder contents, so the converter answers it
//  from folder manifests on its wires, a level per pass, and `XcodeProjectFacts` answers it
//  from the disk for `prepare`; both through this, so the two find the same packages.

import SemelNodeKit

struct LocalPackageSearch {

    /// What one folder holds, as far as the search asks: the names of its files and of its
    /// subfolders.
    struct Contents {
        var files: [String] = []
        var folders: [String] = []

        /// A folder manifest's pushed entries. An unpinned entry is a file or folder that
        /// was deleted or never pushed, and holds no package.
        init(_ manifest: FolderManifest) {
            for entry in manifest.entries where entry.isPinned {
                if entry.isFolder {
                    folders.append(entry.name)
                } else {
                    files.append(entry.name)
                }
            }
        }

        init(files: [String] = [], folders: [String] = []) {
            self.files   = files
            self.folders = folders
        }
    }

    static let manifestName = "Package.swift"

    /// Every folder the search has asked about, relative to the project's folder, in the
    /// order asked: each synchronized folder, and — once its contents are known — each
    /// folder directly in it. What the converter demands a manifest of.
    private(set) var asked: [String] = []

    /// Whether every folder asked about has answered. Until then `packagePaths` holds what
    /// the project declares and what has been found so far.
    private(set) var isComplete = true

    /// The local packages, relative to the project's folder: the ones the project declares
    /// and the ones found in its synchronized folders, each once, sorted.
    private(set) var packagePaths: [String] = []

    /// `contents` answers for a folder relative to the project's folder: what it holds, an
    /// empty `Contents` for a folder that is not there, or nil for one still on its way.
    ///
    /// Only a folder *directly* in a synchronized folder is looked into, which is where
    /// Xcode shows a package and where NetNewsWire's are; a package deeper down, or a
    /// synchronized folder that is itself a package, is not looked for. A folder that is
    /// compiled whole — a catalog — or a language folder is never a package and is not
    /// asked about.
    init(project: XcodeProject, contents: (String) -> Contents?) {
        var found = Set(project.localPackagePaths)
        for folder in project.synchronizedFolderPaths {
            asked.append(folder)
            guard let folderContents = contents(folder) else {
                isComplete = false
                continue
            }
            for child in folderContents.folders.sorted() where !Self.cannotBeAPackage(child) {
                let childPath = "\(folder)/\(child)"
                asked.append(childPath)
                guard let childContents = contents(childPath) else {
                    isComplete = false
                    continue
                }
                if childContents.files.contains(Self.manifestName) {
                    found.insert(childPath)
                }
            }
        }
        packagePaths = found.sorted()
    }

    static func cannotBeAPackage(_ folderName: String) -> Bool {
        folderName.hasPrefix(".") || folderName.hasSuffix(".lproj") || XcodeProjectConverter.isCompiledWhole(folderName)
    }
}
