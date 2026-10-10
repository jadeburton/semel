// DefaultTargetFolders.swift
// SemelSwift
//
// Where a package target that declares no `path:` keeps its sources, found as SwiftPM finds
// it: under the first of its predefined source folders that holds a folder named for the
// target (B-143).

import SemelNodeKit

/// The folder of every target that names none, read from the graph rather than assumed.
///
/// `Sources/<Target>` is SwiftPM's first guess and not its only one: a package may keep its
/// targets under `Source`, `src` or `srcs`, and on the case-insensitive volume a Mac
/// formats by default the folder's case need not be the manifest's. Spelling the first
/// guess into a demand made a folder nobody pushed — a ghost — wherever the package had
/// chosen otherwise, and the target compiled nothing. So the converter asks for the
/// package folder's manifest and each predefined folder's that it holds, a manifest each,
/// and takes the target's folder from what they list. A target none of them holds is the
/// conversion's error, naming the folders tried, as SwiftPM's is; never a demand for a
/// folder that is not there.
public struct DefaultTargetFolders {

    /// SwiftPM's predefined source folders for a regular, executable or system-library
    /// target, in the order it tries them. Public for `prepare`, which finds a target's
    /// folder on disk by the same list.
    public static let predefinedFolders = ["Sources", "Source", "src", "srcs"]

    /// One package, by its folder, and the targets in it that declare no `path:`.
    struct Package {
        let folder: String
        let name: String
        let targets: [String]
    }

    /// A target no predefined folder holds.
    struct Missing: Equatable, CustomStringConvertible {
        let package: String
        let packageFolder: String
        let target: String
        /// The folders looked in, relative to the package.
        let tried: [String]

        var description: String {
            "target \(target) of package \(package) declares no path, and none of the folders SwiftPM looks in "
          + "holds it: \(tried.map { "\(packageFolder)/\($0)" }.joined(separator: ", "))"
        }
    }

    /// The manifests to ask for, by folder path: each package's folder, and each predefined
    /// folder it holds.
    private(set) var specs: [String: GraphSpecNode] = [:]
    /// The folders whose manifests have not arrived.
    private(set) var awaited: [String] = []
    /// Each found target's folder relative to its package, by package folder and target.
    private(set) var found: [String: [String: String]] = [:]
    private(set) var missing: [Missing] = []

    init(packages: [Package], manifests: [String: FolderManifest]) {
        for package in packages where !package.targets.isEmpty {
            specs[package.folder] = .folderManifest(at: package.folder)
            guard let packageManifest = manifests[package.folder] else {
                awaited.append(package.folder)
                continue
            }
            let bases = Self.predefinedFolders.compactMap { Self.folderNamed($0, in: packageManifest) }
            var basesAwaited = false
            for base in bases {
                let path = "\(package.folder)/\(base)"
                specs[path] = .folderManifest(at: path)
                if manifests[path] == nil {
                    awaited.append(path)
                    basesAwaited = true
                }
            }
            guard !basesAwaited else {
                continue
            }
            for target in package.targets {
                let placed = bases.lazy.compactMap { base in
                    manifests["\(package.folder)/\(base)"].flatMap { Self.folderNamed(target, in: $0) }.map { "\(base)/\($0)" }
                }.first
                guard let placed else {
                    missing.append(Missing(package: package.name, packageFolder: package.folder, target: target,
                                           tried: Self.predefinedFolders.map { "\($0)/\(target)" }))
                    continue
                }
                found[package.folder, default: [:]][target] = placed
            }
        }
        awaited.sort()
    }

    /// The pushed subfolder of `manifest` called `name`: the one spelled alike, or else one
    /// spelled alike but for case, as the volume finds it — the first such by bytes, so the
    /// answer does not hang on the order entries were listed in.
    static func folderNamed(_ name: String, in manifest: FolderManifest) -> String? {
        let folders = manifest.entries.filter { $0.isFolder && $0.isPinned }.map(\.name)
        if folders.contains(name) {
            return name
        }
        return folders.filter { $0.lowercased() == name.lowercased() }
                      .min { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
