// DependencyLock.swift
// SemelNodeKit
//
// The lock beside a vendored dependency (B-06): the content root its folder is meant to
// have, and what it was vendored as. Read by the converter that resolves the dependency and
// written by `semel-swift prepare` when it vendors, so the format lives here, where both
// reach it without a toolchain package importing the engine.

import Foundation

/// What a checked-in `Dependencies/<name>.semel-lock` says about `Dependencies/<name>`.
///
/// One line is enforced and the rest are recorded. `content` is the folder's content root
/// (`FolderContentRoot`) as the engine publishes it for the pushed copy, and a build whose
/// copy folds to anything else stops. The other lines answer what a hash cannot: whether
/// this is the library that was meant in the first place — a lock preserves a first-time
/// mistake forever — and whether a published advisory applies. They are never compared,
/// because nothing in a bare source tree says which version it is.
///
/// A text file rather than a value in the graph, because its worth is the diff: a hash in
/// node configuration lives in a database, where it cannot be reviewed, shared between
/// developers or read without Semel running. And beside the folder rather than inside it,
/// for two reasons: a lock in the folder would be a child the root folds, so recording the
/// root would change the root; and `prepare` replaces a `Dependencies/<name>` wholesale
/// when it copies it again.
///
/// `prepare` also reads it back (B-138): a copy whose lock records the pin resolution
/// chose, under the fold `prepare` takes, and whose folder still folds to `content`, is
/// left with its lock untouched, so its root does not move and nothing downstream of it
/// rebuilds.
public struct DependencyLock: Equatable {
    /// The folder's content root, as the object store names it — the hex of a SHA-256.
    public var contentRoot: String
    /// The fold `contentRoot` was taken under: `FolderContentRoot.formatTag` when it was
    /// written. On the lock so that a root the fold moved under reads as a different fold,
    /// not as a different tree.
    public var fold: String
    /// The version the resolver chose, when it chose one; a branch or a revision pin has none.
    public var version: String?
    /// The commit the checkout was at.
    public var revision: String?
    /// Where the dependency came from: its repository URL.
    public var origin: String?
    /// Each binary target's `checksum:` from the manifest, by target (B-77): the SHA-256 of
    /// the zip SwiftPM downloaded and checked before `prepare` copied what it held into
    /// `semel-artifacts`. Recorded, like the version: the copy is what `content` locks.
    public var artifacts: [String: String]
    /// The dot-named files below the folder that its manifest declares as resources, by
    /// path relative to the folder, sorted (B-143). A walk of the disk takes no dot-name,
    /// so `content` would not cover a resource the build reads; each one named here is
    /// folded into `content` as any file is, and a push of the folder sends it
    /// (`FolderOnDisk.read`), so it is locked by the root the lock enforces and not by a
    /// line of its own.
    public var hiddenFiles: [String]

    public init(contentRoot: String, fold: String, version: String? = nil, revision: String? = nil, origin: String? = nil,
                artifacts: [String: String] = [:], hiddenFiles: [String] = []) {
        self.contentRoot = contentRoot
        self.fold        = fold
        self.version     = version
        self.revision    = revision
        self.origin      = origin
        self.artifacts   = artifacts
        self.hiddenFiles = hiddenFiles.sorted()
    }

    // MARK: - Where it lives

    /// `GRDB.swift` is locked by `GRDB.swift.semel-lock` beside it. Not a dot-file: a push
    /// leaves out every name that starts with a dot, and the lock has to reach the graph.
    public static let fileExtension = "semel-lock"

    /// The lock of the dependency whose folder is `folderPath`, in whichever file system
    /// the path is written for: `input:/repo/Dependencies/GRDB.swift` is locked by
    /// `input:/repo/Dependencies/GRDB.swift.semel-lock`.
    public static func lockPath(forDependencyAt folderPath: String) -> String {
        "\(folderPath).\(fileExtension)"
    }

    /// The same, on disk.
    public static func lockFile(forDependencyAt folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent("\(folder.lastPathComponent).\(fileExtension)")
    }

    /// The name a repository is vendored under: `https://github.com/groue/GRDB.swift.git`
    /// is `GRDB.swift`. SwiftPM's own checkout name, and the one `semel-swift prepare`
    /// copies under, so a converter looking for a dependency and the tool that put it there
    /// agree without asking each other.
    ///
    /// From the URL rather than SwiftPM's identity, which is lowercased (`grdb.swift`) and
    /// so cannot name a folder on a case-sensitive file system. Splits on `:` as well as
    /// `/`, so an scp-style remote (`git@host:owner/repo.git`) is named the same way.
    public static func folderName(forRepositoryURL urlString: String) -> String? {
        var name = urlString
        while name.hasSuffix("/") {
            name.removeLast()
        }
        if let lastSeparator = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            name = String(name[name.index(after: lastSeparator)...])
        }
        if name.hasSuffix(".git") {
            name.removeLast(4)
        }
        return name.isEmpty ? nil : name
    }

    /// The folder in a package where `semel-swift prepare` puts a binary target's artifact,
    /// one folder per target (B-77): the `.xcframework` SwiftPM downloaded by `url:` and
    /// checked against its `checksum:`, or a `path:` zip unzipped. Inside the package, so
    /// the lock beside a vendored one covers it, and not a dot-name, which a push leaves
    /// out. Read by the converter that finds the artifact and written by `prepare`, so it
    /// lives here with the rest of the vendoring layout.
    public static let artifactsFolderName = "semel-artifacts"

    // MARK: - The text

    /// The prefix of the `content` value. The value is the root as the store names it; the
    /// prefix says which hash that is, so a reader of the file does not have to know.
    public static let contentScheme = "sha256:"

    enum Key: String, CaseIterable {
        case content
        case fold
        case version
        case revision
        case origin
        case artifacts
        /// Said once per file, the one key that repeats: a path holds any character a
        /// separator could be.
        case hidden
    }

    /// `Sparkle=4d5d…,Other=9e1f…`: the artifacts' checksums on one line, sorted by target.
    static func artifactsText(_ artifacts: [String: String]) -> String? {
        guard !artifacts.isEmpty else {
            return nil
        }
        return artifacts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    /// The first line of every lock, for whoever opens one without knowing what it is.
    static let heading = "# Semel dependency lock (B-06): `content` is enforced, the other lines are recorded only."

    /// The lock as its file holds it: a heading comment, then one `key value` line per
    /// field it has, in a fixed order, the keys padded into a column.
    public var text: String {
        let stated: [Key: String?] = [.content:   Self.contentScheme + contentRoot,
                                      .fold:      fold,
                                      .version:   version,
                                      .revision:  revision,
                                      .origin:    origin,
                                      .artifacts: Self.artifactsText(artifacts)]
        let values = stated.compactMapValues { $0 }.merging(hiddenFiles.isEmpty ? [:] : [.hidden: ""]) { stated, _ in stated }
        // The column is as wide as the widest key, `artifacts` counted only when the lock
        // has it, so a lock of a package with no binary target reads as every lock did.
        let width = Key.allCases.filter { $0 != .artifacts || values[$0] != nil }.map(\.rawValue.count).max() ?? 0
        var lines = [Self.heading]
        // In the order the keys are declared, which is the order a reader expects them in.
        for key in Key.allCases {
            guard let value = values[key] else {
                continue
            }
            let padding = String(repeating: " ", count: width - key.rawValue.count + 2)
            for each in key == .hidden ? hiddenFiles : [value] {
                lines.append("\(key.rawValue)\(padding)\(each)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a lock's text back.
    ///
    /// Strict, because a lock is edited by hand as often as it is written: a key misspelt or
    /// said twice would otherwise be a line nobody reads, and a lock whose `content` line
    /// was dropped would check nothing. A `#` line and a blank line are free.
    public static func parse(_ text: String) throws -> DependencyLock {
        var values: [Key: String] = [:]
        var hiddenFiles: [String] = []
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            let lineNumber = index + 1
            let keyText = String(line.prefix { !$0.isWhitespace })
            let value   = line.dropFirst(keyText.count).trimmingCharacters(in: .whitespaces)
            guard let key = Key(rawValue: keyText) else {
                throw DependencyLockError.unknownKey(keyText, line: lineNumber)
            }
            if key == .hidden {
                guard isHiddenFilePath(value), !hiddenFiles.contains(value) else {
                    throw DependencyLockError.malformedHiddenFile(value, line: lineNumber)
                }
                hiddenFiles.append(value)
                continue
            }
            guard values[key] == nil else {
                throw DependencyLockError.repeatedKey(keyText, line: lineNumber)
            }
            guard !value.isEmpty else {
                throw DependencyLockError.emptyValue(keyText, line: lineNumber)
            }
            values[key] = value
        }

        guard let content = values[.content] else {
            throw DependencyLockError.missingKey(Key.content.rawValue)
        }
        guard content.hasPrefix(contentScheme), content.count > contentScheme.count else {
            throw DependencyLockError.unknownContentScheme(content)
        }
        guard let fold = values[.fold] else {
            throw DependencyLockError.missingKey(Key.fold.rawValue)
        }
        var artifacts: [String: String] = [:]
        for item in (values[.artifacts] ?? "").split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, artifacts[parts[0]] == nil else {
                throw DependencyLockError.malformedArtifact(String(item))
            }
            artifacts[parts[0]] = parts[1]
        }
        return DependencyLock(contentRoot: String(content.dropFirst(contentScheme.count)),
                              fold:        fold,
                              version:     values[.version],
                              revision:    values[.revision],
                              origin:      values[.origin],
                              artifacts:   artifacts,
                              hiddenFiles: hiddenFiles)
    }

    /// Whether `path` can name a file a `hidden` line covers: relative, below the folder,
    /// its last component dot-named and no other, since a push takes a dot-named file by
    /// its name in a folder it walks and never walks into a dot-named folder.
    public static func isHiddenFilePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), let last = components.last, last.hasPrefix("."), last != ".", last != ".." else {
            return false
        }
        return components.dropLast().allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// The hidden files as `FolderOnDisk.read` takes them: by the path of their folder,
    /// relative to the folder `under` names (empty for the locked folder itself).
    public func hiddenFilesByFolder(under folder: Path = .empty) -> [String: [String]] {
        var byFolder: [String: [String]] = [:]
        for file in hiddenFiles {
            let path = folder / Path(file)
            guard let name = path.lastComponent else {
                continue
            }
            byFolder[(path.deletingLastComponent ?? .empty).string, default: []].append(name)
        }
        return byFolder
    }
}

/// Why a lock's text could not be read, by the line that says so.
public enum DependencyLockError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String, line: Int)
    case repeatedKey(String, line: Int)
    case emptyValue(String, line: Int)
    case missingKey(String)
    case unknownContentScheme(String)
    /// An `artifacts` item that is not `<target>=<checksum>`, or names a target twice.
    case malformedArtifact(String)
    /// A `hidden` path that is not a dot-named file below the folder, or is named twice.
    case malformedHiddenFile(String, line: Int)

    public var description: String {
        let keys = DependencyLock.Key.allCases.map(\.rawValue).joined(separator: ", ")
        switch self {
        case .unknownKey(let key, let line):
            return "line \(line): '\(key)' is not a lock key; the keys are \(keys)"
        case .repeatedKey(let key, let line):
            return "line \(line): '\(key)' is said a second time"
        case .emptyValue(let key, let line):
            return "line \(line): '\(key)' has no value"
        case .missingKey(let key):
            return "there is no '\(key)' line"
        case .unknownContentScheme(let value):
            return "'content' is '\(value)', and a content root is written '\(DependencyLock.contentScheme)<hex>'"
        case .malformedHiddenFile(let path, let line):
            return "line \(line): 'hidden' holds '\(path)', and each is a relative path, said once, to a dot-named file "
                 + "in no dot-named folder"
        case .malformedArtifact(let item):
            return "'artifacts' holds '\(item)', and each of its comma-separated items is written '<target>=<checksum>', a target once"
        }
    }
}
