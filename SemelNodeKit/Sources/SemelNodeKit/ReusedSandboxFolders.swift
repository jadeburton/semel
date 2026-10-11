//
//  ReusedSandboxFolders.swift
//  SemelNodeKit
//
//  Sandbox folders that are emptied rather than removed, for the tools that leave a
//  process behind in the folder they ran in (B-152).
//

import Foundation

/// A set of folders, `slot-0`, `slot-1`, …, under one parent, each a sandbox for one run at
/// a time: taken under an advisory lock on its `slot-N.lock` file, so two processes — a
/// server and a test run on one machine — never share one, emptied before the run and
/// after it, and never removed.
///
/// Why: `ibtool` and `actool` hand their work to a per-user `ibtoold` daemon, which on Xcode
/// 26.6 changes its working directory to the client's for a request and, after an `actool`
/// request, stays there. Measured 2026-10-11: six `actool` runs from six folders left five
/// daemons in five of those folders; with the folders removed, every `ibtool` run on the
/// machine after them failed — twelve of twelve, from a folder that existed — with
/// `IBCurrentDirectoryPath … currentDirectoryPath is unexpectedly nil`, until the daemons
/// exited, about two minutes idle. A fresh temporary sandbox, removed after each run, is
/// therefore a poisoned daemon after the first catalog. Starting the daemon first from a
/// lasting folder does not help: a daemon started by `ibtool --version`, from any folder,
/// sits in `/` until a request moves it, and the request moves it to the client's working
/// directory. Running the client from a lasting folder and naming the sandbox by absolute
/// paths would put the sandbox on the command line, which `ToolSandbox` forbids. So the
/// client's working directory has to outlive the run, and is a folder that is reused
/// instead of removed. What the tool is told is unchanged: every path is relative to the
/// folder, which starts each run empty, so the command line and the outputs are what a
/// temporary sandbox gave.
///
/// The folder's contents are never an input: a slot is emptied before a run takes it and
/// after it, so a run sees only what it was handed, and hermeticity is what it was. The
/// slots live outside `SEMEL_HOME` on purpose (`SemelPaths.reusedSandboxFolders`): a home
/// is removed with the test or the session that made it, and a daemon left in a slot of a
/// removed home is the failure this exists to prevent. One set per user, as the daemons
/// are one pool per user.
public struct ReusedSandboxFolders {
    /// The parent of the slots.
    public let parent: URL

    public init(parent: URL) {
        self.parent = parent
    }

    /// More slots than this is more runs of one tool at once than any machine holds cores;
    /// past it, something is leaking locks.
    static let slotLimit = 512

    /// One slot taken for a run: its folder, empty, and the lock that holds it.
    struct Slot {
        let folder: URL
        fileprivate let lockDescriptor: Int32
    }

    /// Takes the first slot no run holds, empties it and hands it over.
    func take() throws -> Slot {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        for index in 0..<Self.slotLimit {
            let lockPath = parent.appendingPathComponent("slot-\(index).lock").path
            let descriptor = open(lockPath, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    continue
                }
                throw SandboxCreationError(underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            let folder = parent.appendingPathComponent("slot-\(index)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                try Self.empty(folder)
            } catch {
                close(descriptor)
                throw SandboxCreationError(underlying: error)
            }
            return Slot(folder: folder, lockDescriptor: descriptor)
        }
        throw SandboxCreationError(underlying: POSIXError(.EBUSY))
    }

    /// Empties the slot's folder, keeping the folder, and lets another run take it.
    func give(back slot: Slot) {
        try? Self.empty(slot.folder)
        close(slot.lockDescriptor)
    }

    /// Removes everything in `folder`, hidden entries too, and leaves the folder.
    static func empty(_ folder: URL) throws {
        let fileManager = FileManager.default
        for name in try fileManager.contentsOfDirectory(atPath: folder.path) {
            try fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
