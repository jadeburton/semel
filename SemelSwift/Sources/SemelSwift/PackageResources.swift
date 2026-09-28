// PackageResources.swift
// SemelSwift
//
// What a package target carries besides sources, and how each piece gets into the
// target's resource bundle (B-77).
//
// SwiftPM builds a bundle named `<Package>_<Target>.bundle` for a target with resources
// and generates a `Bundle.module` accessor into the target's sources. Two kinds of
// resource reach that bundle: the ones the manifest declares (`.process` and `.copy`
// rules), and the ones SwiftPM recognises by type wherever they sit in the target's
// folder — an asset catalog, an `.lproj` folder, a string catalog. This file is the
// reading of a target's folder tree by those rules; the converter turns the result into
// the nodes that compile or copy each piece.

import Foundation
import SemelNodeKit

/// One resource of a target: where it is, and where it lands in the bundle.
struct PackageResource: Equatable {

    enum Kind: Equatable {
        /// An `.xcassets` folder, compiled by the asset compiler into `Assets.car` and
        /// whatever else the platform wants; the compiler decides the paths.
        case assetCatalog
        /// An `.lproj` folder, copied whole under its own name at the bundle's root,
        /// wherever it sat in the target: a bundle finds its localizations there.
        case localizedFolder
        /// An `.xcstrings` file, compiled to one `.strings` per language.
        case stringCatalog
        /// A folder copied as it is, under `bundlePath`.
        case folder
        /// A single file copied as it is, at `bundlePath`.
        case file
    }

    let kind: Kind
    /// Relative to the target's folder.
    let path: String
    /// Where it lands in the bundle: `en.lproj`, `config.json`, `Data`. Empty for a
    /// catalog, whose compiler decides.
    let bundlePath: String
}

enum PackageResources {

    /// What the manifest says about a target's resources: its `resources:` rules and the
    /// scope its `sources:` and `exclude:` draw.
    struct Rules: Equatable {
        struct Declared: Equatable {
            let path: String
            /// `.copy` keeps the file or folder as it is; `.process` flattens a folder and
            /// hands each recognised type to its compiler.
            let isCopy: Bool
        }

        let declared: [Declared]
        let sources: [String]
        let exclude: [String]

        init(declared: [Declared] = [], sources: [String] = [], exclude: [String] = []) {
            self.declared = declared
            self.sources  = sources
            self.exclude  = exclude
        }
    }

    /// Folders that are one resource each, never walked into.
    static let wholeFolderExtensions: Set<String> = ["xcassets", "lproj", "xcdatamodeld", "icon", "rkassets",
                                                     "xcmappingmodel", "bundle"]

    /// Files SwiftPM treats as resources by type, wherever they sit.
    static let resourceFileExtensions: Set<String> = ["xcstrings", "storyboard", "xib", "nib", "metal"]

    /// Whether the converter's walk descends into a folder of this name: not a hidden
    /// one, and not one that is a resource whole.
    static func isWalked(folderName: String) -> Bool {
        !folderName.hasPrefix(".") && !wholeFolderExtensions.contains((folderName as NSString).pathExtension.lowercased())
    }

    /// Every resource of `target`, whose folder is `targetFolder`, read from `manifests`
    /// — the folder's own and every subfolder's the converter walked, keyed by path.
    /// Sorted by path, so the formula is the same on every run.
    static func detect(rules target: Rules,
                       targetFolder: String,
                       manifests: [String: FolderManifest]) -> [PackageResource] {
        var found: [PackageResource] = []
        var claimed = Set<String>()

        func claim(_ resource: PackageResource) {
            guard claimed.insert(resource.path).inserted else { return }
            found.append(resource)
        }

        /// What one file or folder at `relative` is, by type; nil when it is a source or
        /// nothing SwiftPM recognises.
        func recognised(relative: String, isFolder: Bool, flattenedTo bundlePath: String) -> PackageResource? {
            let name = (relative as NSString).lastPathComponent
            let ext  = (name as NSString).pathExtension.lowercased()
            if isFolder {
                switch ext {
                case "xcassets": return PackageResource(kind: .assetCatalog, path: relative, bundlePath: "")
                case "lproj":    return PackageResource(kind: .localizedFolder, path: relative, bundlePath: name)
                default:
                    return wholeFolderExtensions.contains(ext) ? PackageResource(kind: .folder, path: relative, bundlePath: name) : nil
                }
            }
            if ext == "xcstrings" {
                return PackageResource(kind: .stringCatalog, path: relative, bundlePath: "")
            }
            return resourceFileExtensions.contains(ext) ? PackageResource(kind: .file, path: relative, bundlePath: bundlePath) : nil
        }

        /// Walks the tree under `relative` (empty for the target folder itself), calling
        /// `visit` for each entry with whether it is a folder; a folder that is a resource
        /// whole is visited and not entered.
        func walk(_ relative: String, visit: (String, Bool) -> Void) {
            let folderPath = relative.isEmpty ? targetFolder : "\(targetFolder)/\(relative)"
            guard let manifest = manifests[folderPath] else { return }
            for entry in manifest.entries.sorted(by: { $0.name < $1.name }) where entry.isPinned {
                let entryPath = relative.isEmpty ? entry.name : "\(relative)/\(entry.name)"
                guard !isExcluded(entryPath, by: target) else { continue }
                visit(entryPath, entry.isFolder)
                if entry.isFolder, isWalked(folderName: entry.name) {
                    walk(entryPath, visit: visit)
                }
            }
        }

        // The manifest's rules first: a copy keeps its shape, a processed folder is
        // flattened to the bundle's root except for what is recognised by type.
        for declared in target.declared {
            let isFolder = manifests[fullPath(targetFolder: targetFolder, relative: declared.path)] != nil
            let name = (declared.path as NSString).lastPathComponent
            if declared.isCopy {
                claim(PackageResource(kind: isFolder ? .folder : .file, path: declared.path, bundlePath: name))
            } else {
                if isFolder {
                    if let whole = recognised(relative: declared.path, isFolder: true, flattenedTo: name) {
                        claim(whole)
                        continue
                    }
                    walk(declared.path) { entryPath, entryIsFolder in
                        let entryName = (entryPath as NSString).lastPathComponent
                        if let resource = recognised(relative: entryPath, isFolder: entryIsFolder, flattenedTo: entryName) {
                            claim(resource)
                        } else if !entryIsFolder, !isInsideWholeFolder(entryPath) {
                            claim(PackageResource(kind: .file, path: entryPath, bundlePath: entryName))
                        }
                    }
                } else {
                    claim(recognised(relative: declared.path, isFolder: false, flattenedTo: name)
                          ?? PackageResource(kind: .file, path: declared.path, bundlePath: name))
                }
            }
        }

        // Then what the folder holds that SwiftPM recognises by type, within the target's
        // sources scope, whatever the manifest said.
        walk("") { entryPath, entryIsFolder in
            guard target.sources.isEmpty || target.sources.contains(where: { isAtOrUnder(entryPath, $0) }) else { return }
            if let resource = recognised(relative: entryPath, isFolder: entryIsFolder, flattenedTo: (entryPath as NSString).lastPathComponent) {
                claim(resource)
            }
        }

        return found.sorted { $0.path < $1.path }
    }

    /// Where a resource declared relative to the target folder is, with its dot segments
    /// resolved. A manifest may declare `.copy("../Sources/PrivacyInfo.xcprivacy")` from a
    /// target at `Sources` (purchases-ios does); spelled into a formula as it stands, that
    /// path made the engine a folder called `..` under `Sources` and a file in it nothing
    /// could ever push — a ghost that moved the package folder's content root off its lock
    /// (B-125). A path that climbs above the file system's root names nothing, and is left
    /// as it stands for the report to show.
    static func fullPath(targetFolder: String, relative: String) -> String {
        let joined = Path("\(targetFolder)/\(relative)")
        return (joined.resolvingDotSegments ?? joined).string
    }

    private static func isExcluded(_ relative: String, by target: Rules) -> Bool {
        target.exclude.contains { isAtOrUnder(relative, $0) }
    }

    private static func isInsideWholeFolder(_ relative: String) -> Bool {
        relative.split(separator: "/").dropLast().contains {
            wholeFolderExtensions.contains((String($0) as NSString).pathExtension.lowercased())
        }
    }

    static func isAtOrUnder(_ path: String, _ prefix: String) -> Bool {
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return path == trimmed || path.hasPrefix(trimmed + "/")
    }
}
