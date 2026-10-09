// DependencyLockCheck.swift
// SemelSwift
//
// B-06: every package the converter reads from the root's `Dependencies` folder is compared
// with the lock beside it, so a vendored dependency that moved is reported rather than
// silently rebuilt.

import SemelNodeKit
import SemelDatabaseModels

/// The comparison between each vendored package's folder and its `.semel-lock`.
///
/// Nothing here guards the cache: a vendored file is a `StaticFile` like any other, so an
/// edit to one already changes the key of everything downstream. What the lock adds is
/// consent. Without it the change is absorbed — the graph rebuilds and succeeds, and nobody
/// is told their dependency moved; with it the build stops and names the expected and the
/// found root, which is what `Package.resolved` and `yarn.lock` are for.
///
/// Three wires per package, all demanded by the converter on dynamic ports: the lock file,
/// and — only once the lock turns out to be there — the folder's pushed content root, which
/// is compared, and its whole one, which is read only to say what the comparison left out.
/// A tree without locks is therefore not woken by every edit below its vendored folders,
/// and a tree with them is, which is the point of having them.
///
/// The pushed root, because the lock is folded from a copy on disk by the walk a push
/// makes, and the graph can hold below the folder what that walk never sees: a dot-named
/// file something asked for by name, a name the converter demanded that the copy lacks.
/// The pushed root leaves out exactly those (B-143), so a copy nobody touched matches its
/// lock whatever else the build asked of it.
struct DependencyLockCheck {

    /// The package folders compared, sorted: every one directly under the dependencies
    /// folder, whoever declared it — the root package itself included, which is how a
    /// package an Xcode project references is checked when the project's formula names it
    /// by its vendored folder.
    let folders: [String]

    init(packageFolders: some Sequence<String>, dependenciesFolder: String) {
        let prefix = dependenciesFolder + "/"
        folders = Set(packageFolders.filter { folder in
            folder.hasPrefix(prefix) && !folder.dropFirst(prefix.count).contains("/")
        }).sorted()
    }

    /// The lock of each package, by the lock's path. A lock nobody pushed is a file nobody
    /// pushed: the wire comes from a ghost, and pushing the lock later fills it.
    var lockSpecs: [String: GraphSpecNode] {
        var specs: [String: GraphSpecNode] = [:]
        for folder in folders {
            let lockPath = DependencyLock.lockPath(forDependencyAt: folder)
            specs[lockPath] = .staticFile(at: lockPath)
        }
        return specs
    }

    /// The pushed content root of each package whose lock arrived with something in it, by
    /// the folder's path: what the lock is compared with.
    func contentRootSpecs(locks: [String: NodeValue]) -> [String: GraphSpecNode] {
        var specs: [String: GraphSpecNode] = [:]
        for folder in lockedFolders(locks: locks) {
            specs[folder] = .folderPushedContentRoot(at: folder)
        }
        return specs
    }

    /// The whole content root of the same packages, by the folder's path: read when a lock
    /// fails, to name what the graph holds below the folder that the comparison left out.
    func wholeContentRootSpecs(locks: [String: NodeValue]) -> [String: GraphSpecNode] {
        var specs: [String: GraphSpecNode] = [:]
        for folder in lockedFolders(locks: locks) {
            specs[folder] = .folderContentRoot(at: folder)
        }
        return specs
    }

    private func lockedFolders(locks: [String: NodeValue]) -> [String] {
        folders.filter { locks[DependencyLock.lockPath(forDependencyAt: $0)]?.isNoValue == false }
    }

    enum Outcome: Equatable {
        /// A lock, or the root it is compared with, has not arrived yet.
        case waiting(folders: [String])
        /// Every lock there matches; the folders with no lock beside them are named.
        case passed(unlocked: [String])
        /// At least one lock does not match, or cannot be read.
        case failed([Problem])
    }

    /// What is wrong with one package's lock, by case: the converter's message is rendered
    /// from these, and a test asks which case it got.
    enum Problem: Equatable, CustomStringConvertible {
        /// The folder's pushed root is not the root the lock records. `leftOut` is what the
        /// graph holds below the folder that neither root folds, when its whole root could
        /// be read.
        case mismatch(folder: String, lock: DependencyLock, found: DataObjectHash, leftOut: [LeftOutEntry])
        /// The lock was taken under another fold, so its root cannot be compared with this
        /// Semel's: the tree may be exactly what was vendored.
        case foldChanged(folder: String, lock: DependencyLock)
        /// The lock's text is not a lock.
        case unreadable(folder: String, error: DependencyLockError)

        var description: String {
            switch self {
            case .mismatch(let folder, let lock, let found, let leftOut):
                return "\(folder) is not the tree its lock records.\n"
                     + "  lock:     \(Self.describe(lockOf: folder, lock))\n"
                     + "  expected: \(DependencyLock.contentScheme)\(lock.contentRoot)\n"
                     + "  found:    \(DependencyLock.contentScheme)\(found)\n"
                     + Self.describe(leftOut: leftOut)
                     + "If the change is meant — the dependency updated or patched — `semel-swift prepare` on the "
                     + "project vendors it again and rewrites the lock, or put the found hash on the lock's `content` "
                     + "line. If it is not, vendor it again: the copy is not what was locked."
            case .foldChanged(let folder, let lock):
                return "\(folder) cannot be compared with its lock.\n"
                     + "  lock:     \(Self.describe(lockOf: folder, lock))\n"
                     + "  The lock's content root was folded as '\(lock.fold)', and this Semel folds as "
                     + "'\(FolderContentRoot.formatTag)', so the tree may well be unchanged. "
                     + "`semel-swift prepare` on the project writes the lock again under the current fold."
            case .unreadable(let folder, let error):
                return "\(DependencyLock.lockPath(forDependencyAt: folder)) is not a lock: \(error). "
                     + "`semel-swift prepare` on the project writes it again."
            }
        }

        /// What the comparison did not fold, by reason, a few paths each. None of it is what
        /// differs — a push of the folder sends none of it, and the copy's fold leaves it
        /// out alike — so the difference is in what both read: a file edited, or one the
        /// graph keeps from an earlier copy because a push only adds.
        static func describe(leftOut: [LeftOutEntry]) -> String {
            guard !leftOut.isEmpty else {
                return ""
            }
            let groups: [(reason: LeftOutEntry.Reason, label: String)] = [
                (.dotNamed,     "dot-named"),
                (.notPushed,    "asked for and never pushed"),
                (.removed,      "removed"),
                (.product,      "products"),
                (.failed,       "failed"),
                (.holdsNothing, "folders holding nothing a push sends"),
            ]
            var text = "  Not compared, as a push of the folder sends none of it and the lock leaves it out:\n"
            for group in groups {
                let paths = leftOut.filter { $0.reason == group.reason }.map(\.path)
                guard !paths.isEmpty else {
                    continue
                }
                let shown = paths.prefix(pathsNamed).joined(separator: ", ")
                let more  = paths.count > pathsNamed ? ", and \(paths.count - pathsNamed) more" : ""
                text += "    \(paths.count) \(group.label): \(shown)\(more)\n"
            }
            return text
        }

        /// How many paths of each kind a failed lock names before it counts the rest.
        static let pathsNamed = 5

        /// The lock's path, with what it records about where the package came from.
        private static func describe(lockOf folder: String, _ lock: DependencyLock) -> String {
            let recorded = [lock.version.map { "version \($0)" }, lock.origin.map { "from \($0)" }].compactMap { $0 }
            let path = DependencyLock.lockPath(forDependencyAt: folder)
            return recorded.isEmpty ? path : "\(path) (\(recorded.joined(separator: ", ")))"
        }
    }

    /// Compares every package that has a lock with the lock, from the values on the two
    /// ports the specs above fill.
    ///
    /// A lock that is not there is not a failure. Every tree vendored before locks existed
    /// is in that state, and so is one vendored by hand; the converter says so in a notice
    /// and builds. A lock that is there is the user's statement of what the folder holds,
    /// and a folder holding anything else stops the build.
    func outcome(locks: [String: NodeValue], contentRoots: [String: NodeValue],
                 wholeContentRoots: [String: NodeValue]) throws -> Outcome {
        var waiting:  [String] = []
        var unlocked: [String] = []
        var problems: [Problem] = []

        for folder in folders {
            guard let lockValue = locks[DependencyLock.lockPath(forDependencyAt: folder)] else {
                waiting.append(folder)
                continue
            }
            // A ghost, a lock taken back out: either way, nothing to compare with.
            guard case .value(let lockHash) = lockValue else {
                unlocked.append(folder)
                continue
            }
            let lock: DependencyLock
            do {
                lock = try DependencyLock.parse(try lockHash.resolveAsString())
            } catch let error as DependencyLockError {
                problems.append(.unreadable(folder: folder, error: error))
                continue
            }
            guard case .value(let found) = contentRoots[folder] else {
                waiting.append(folder)
                continue
            }
            guard lock.fold == FolderContentRoot.formatTag else {
                problems.append(.foldChanged(folder: folder, lock: lock))
                continue
            }
            if lock.contentRoot != found {
                // What was not compared is said when it can be read, and the mismatch is
                // the error either way.
                var leftOut: [LeftOutEntry] = []
                if case .value(let wholeRoot)? = wholeContentRoots[folder] {
                    leftOut = (try? FolderContentRoot.entriesLeftOutOfThePushedRoot(below: wholeRoot)) ?? []
                }
                problems.append(.mismatch(folder: folder, lock: lock, found: found, leftOut: leftOut))
            }
        }

        guard problems.isEmpty else {
            return .failed(problems)
        }
        guard waiting.isEmpty else {
            return .waiting(folders: waiting)
        }
        return .passed(unlocked: unlocked)
    }

    /// The notice for packages with no lock beside them: one line, since it is said on
    /// every conversion that reaches them.
    static func notice(unlocked: [String]) -> String {
        let names = unlocked.map { String($0.split(separator: "/").last ?? Substring($0)) }
        return "No lock beside \(unlocked.count) vendored package\(unlocked.count == 1 ? "" : "s") "
             + "(\(names.joined(separator: ", "))): nothing checks that \(unlocked.count == 1 ? "it is" : "they are") "
             + "what was vendored. `semel-swift prepare` writes a <name>.\(DependencyLock.fileExtension) beside each."
    }
}
