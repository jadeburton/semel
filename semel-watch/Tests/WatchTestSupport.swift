//
//  WatchTestSupport.swift
//  SemelWatchTests
//
//  The two adapters a watcher has, as a test fills them: a stream fed by hand and a clock
//  that moves only when the stream says, a disk that holds the paths a test names, and a
//  graph that holds the paths a test names.
//

import Foundation
import SemelNodeKit
@testable import SemelWatch

/// A clock that moves only when told.
final class ManualClock: WatchClock {
    private(set) var now: Duration = .zero

    func advance(by duration: Duration) {
        now += duration
    }

    func sleep(for duration: Duration) {
        advance(by: duration)
    }
}

/// A stream that hands out what a test queued, and spends the time a wait would have
/// spent on the test's clock rather than the wall's.
final class ManualEvents: FileEvents {

    enum Item {
        /// Paths reported at once.
        case events([FileEvent])
        /// The disk stays quiet for as long as the watcher waits: its whole quiet interval.
        case quiet
    }

    private let clock: ManualClock
    private var queue: [Item]
    private(set) var isStopped = false

    init(clock: ManualClock, _ queue: [Item]) {
        self.clock = clock
        self.queue = queue
    }

    /// Paths, as a stream reports them, all at once.
    static func reporting(_ paths: String...) -> Item {
        .events(paths.map { FileEvent(path: Path($0)) })
    }

    func next(waitingAtMost timeout: Duration?) -> FileEventsYield {
        guard !isStopped else {
            return .ended
        }
        guard !queue.isEmpty else {
            // Nothing more will be reported: the wait times out while a batch is pending,
            // and the stream ends once nothing is.
            guard let timeout else {
                return .ended
            }
            clock.advance(by: timeout)
            return .timedOut
        }
        switch queue.removeFirst() {
        case .events(let reported):
            return .events(reported)
        case .quiet:
            clock.advance(by: timeout ?? .zero)
            return .timedOut
        }
    }

    func stop() {
        isStopped = true
    }
}

/// A disk holding the files and folders a test names, listed as `ExternalFileSystemLister`
/// lists one: dot-names left out of a listing, a dot-named file found when named exactly.
final class FakeDisk: FileWildcardMatcherInput {
    let rootDirectoryPath = "/disk"
    private var kinds: [Path: FileWildcardEntryKind] = [:]

    /// Every file named, and every folder on the way to one; `folders` for an empty one.
    init(files: [String], folders: [String] = []) {
        for file in files {
            add(Path(file), as: .file)
        }
        for folder in folders {
            add(Path(folder), as: .folder)
        }
    }

    private func add(_ path: Path, as kind: FileWildcardEntryKind) {
        kinds[path] = kind
        var folder = Path(segments: path.segments.dropLast())
        while !folder.isEmpty {
            kinds[folder] = .folder
            folder = Path(segments: folder.segments.dropLast())
        }
    }

    private func folder(of directoryPath: String) -> Path {
        Path(String(directoryPath.dropFirst(rootDirectoryPath.count)))
    }

    func allFiles(inDirectoryPath directoryPath: String) -> [FileWildcardEntry] {
        let folder = folder(of: directoryPath)
        return kinds
            .filter { Path(segments: $0.key.segments.dropLast()) == folder && $0.key.count == folder.count + 1 }
            .compactMap { path, kind -> FileWildcardEntry? in
                guard let name = path.lastComponent, !name.hasPrefix(".") else {
                    return nil
                }
                return FileWildcardEntry(path: Path(name), kind: kind, state: nil, isUnreferenced: false)
            }
            .sorted { $0.path.string < $1.path.string }
    }

    func hiddenFile(named name: String, inDirectoryPath directoryPath: String) -> FileWildcardEntry? {
        guard name.hasPrefix("."), kinds[folder(of: directoryPath) / name] == .file else {
            return nil
        }
        return FileWildcardEntry(path: Path(name), kind: .file, state: nil, isUnreferenced: false)
    }
}

/// A graph holding exactly the paths a test names, and recording what it was asked.
final class HeldPaths: InputHoldings {
    private let held: Set<Path>
    private(set) var asked: [Path] = []

    init(_ paths: String...) {
        held = Set(paths.map { Path($0) })
    }

    func holds(_ path: Path) -> Bool {
        asked.append(path)
        return held.contains(path)
    }

    /// The paths named below `folder`, each a folder when another named path lies below it.
    func holdings(below folder: Path) -> [FileWildcardEntry] {
        held.filter { $0 != folder && $0.hasPrefix(folder) }
            .sorted(by: Path.precedes)
            .map { path in
                let isFolder = held.contains { $0 != path && $0.hasPrefix(path) }
                return FileWildcardEntry(path: path, kind: isFolder ? .folder : .file, state: .present, isUnreferenced: false)
            }
    }
}

/// A fresh directory under the system's temporary one, removed by the test's teardown.
func makeTemporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("semel-watch-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Links resolved, as the watcher's base is: `/var` is `/private/var` on this system.
    return directory.resolvingSymlinksInPath()
}
