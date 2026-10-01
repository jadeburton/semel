//
//  FSEventsStream.swift
//  semel-watch
//
//  The one conformance of `FileEvents` that touches the disk: an FSEvents stream over the
//  base (B-126). Everything it reports is a path relative to the base; what to do about
//  each is decided above it, from the disk, when the quiet interval ends.
//

import CoreServices
import Foundation
import SemelNodeKit
import SemelWatch

final class FSEventsStream: FileEvents {

    enum Failure: Error, CustomStringConvertible {
        case notOpened(path: String, reason: String)
        case notCreated(path: String)
        case notStarted(path: String)

        var description: String {
            switch self {
            case .notOpened(let path, let reason): return "cannot watch \(path): \(reason)"
            case .notCreated(let path):            return "FSEvents would not create a stream over \(path)"
            case .notStarted(let path):            return "FSEvents would not start the stream over \(path)"
            }
        }
    }

    /// The base as the kernel spells it — the case on disk, `/private` before `/tmp` — which
    /// is how FSEvents spells the paths it reports.
    private let canonicalBase: String
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "semel-watch.fsevents")

    private let condition = NSCondition()
    private var pending: [FileEvent] = []
    private var stopped = false

    /// One stream over `base`, every file's events (`FileEvents`), the first event of a
    /// quiet spell delivered at once (`NoDefer`), and `latency` — the quiet interval — for
    /// the rest of a burst, which the coalescer then waits out again.
    init(base: String, latency: Duration) throws {
        canonicalBase = try Self.canonicalPath(of: base)

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else {
                return
            }
            let stream = Unmanaged<FSEventsStream>.fromOpaque(info).takeUnretainedValue()
            let reported = unsafeBitCast(paths, to: NSArray.self)
            var events: [(path: String, flags: FSEventStreamEventFlags)] = []
            for index in 0..<count {
                guard let path = reported[index] as? String else {
                    continue
                }
                events.append((path, eventFlags[index]))
            }
            stream.receive(events)
        }
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                                [canonicalBase] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                latency.timeInterval, flags) else {
            throw Failure.notCreated(path: canonicalBase)
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw Failure.notStarted(path: canonicalBase)
        }
    }

    deinit {
        tearDown()
    }

    // MARK: - FileEvents

    func next(waitingAtMost timeout: Duration?) -> FileEventsYield {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0.timeInterval) }
        while pending.isEmpty && !stopped {
            if let deadline {
                guard condition.wait(until: deadline) else {
                    return stopped ? .ended : .timedOut
                }
            } else {
                condition.wait()
            }
        }
        guard !stopped else {
            return .ended
        }
        defer { pending = [] }
        return .events(pending)
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
        queue.async { [weak self] in self?.tearDown() }
    }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    // MARK: - Receiving

    /// Each reported path made relative to the base. A path outside it — the base renamed
    /// away, reported by its old name — and the base itself are left out unless the stream
    /// says it lost track, which rescans whatever it names: the base whole, if need be.
    private func receive(_ reported: [(path: String, flags: FSEventStreamEventFlags)]) {
        let lostTrack = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                | kFSEventStreamEventFlagUserDropped
                                                | kFSEventStreamEventFlagKernelDropped
                                                | kFSEventStreamEventFlagHistoryDone)
        var events: [FileEvent] = []
        for (path, flags) in reported {
            let needsRescan = flags & lostTrack != 0
            guard let relative = relativePath(of: path) else {
                if needsRescan {
                    events.append(FileEvent(path: .empty, needsRescan: true))
                }
                continue
            }
            guard !relative.isEmpty || needsRescan else {
                continue
            }
            events.append(FileEvent(path: relative, needsRescan: needsRescan))
        }
        guard !events.isEmpty else {
            return
        }
        condition.lock()
        pending.append(contentsOf: events)
        condition.signal()
        condition.unlock()
    }

    /// `path` relative to the base, or nil when it is not under it. FSEvents spells paths
    /// as the kernel does, but a case-insensitive volume answers to any case, so the
    /// comparison ignores it.
    private func relativePath(of path: String) -> Path? {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.count >= canonicalBase.count,
              trimmed.prefix(canonicalBase.count).caseInsensitiveCompare(canonicalBase) == .orderedSame else {
            return nil
        }
        let rest = trimmed.dropFirst(canonicalBase.count)
        guard rest.isEmpty || rest.hasPrefix("/") else {
            return nil
        }
        return Path(String(rest))
    }

    private func tearDown() {
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The path the kernel holds for the directory at `path`: its case on disk, every link
    /// resolved.
    private static func canonicalPath(of path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw Failure.notOpened(path: path, reason: String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw Failure.notOpened(path: path, reason: String(cString: strerror(errno)))
        }
        return String(cString: buffer)
    }
}
