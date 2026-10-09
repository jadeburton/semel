// RequestHandler+Batches.swift
// SemelServer
//
// A batch is all or nothing (B-146). `begin` opens a journal for the session, every push,
// link push and removal records what its path held before it writes, and the outermost
// `commit` puts the batch through the lock barrier: it stands, or it is replayed whole and
// the client is told why. A push outside any batch is a batch of one and is checked the
// same. The checkpoint verbs live here too, since a restore is a batch like any other.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

extension RequestHandler {

    // MARK: - Opening and closing

    /// Opens a batch: the outermost `begin` of a session opens its journal and holds back
    /// the engine's wake-up; a nested one only counts, sharing the journal.
    func openBatch(_ session: Session) throws {
        if session.openBatchDepth == 0 {
            session.journal = try BatchJournal(identifier: session.identifier)
            engine.beginBatch()
        }
        session.batchOpened()
    }

    /// Closes a batch. A nested `commit` only counts; the outermost puts the journal
    /// through the barrier and lets the engine go, and throws the rejection when the
    /// barrier refused the batch — with the session's depth at zero either way, since a
    /// refused batch has been taken back whole and there is nothing left open to commit.
    func closeBatch(_ session: Session) throws {
        guard session.openBatchDepth > 0 else {
            return
        }
        guard session.openBatchDepth == 1 else {
            session.batchClosed()
            return
        }
        let journal = session.journal
        session.journal = nil
        session.batchClosed()

        var wakesTheLoop = true
        defer { engine.endBatch(wakingTheLoop: wakesTheLoop) }
        guard let journal, let rejection = try LockBarrier.commit(journal) else {
            return
        }
        // The replay put `input:` back, and its flush folded the folders back to what they
        // held. What it cannot take back is a consumer the batch's writes scheduled before
        // it was refused; that one wants a pass, whose every node reads what it read before
        // and is answered from the cache. Nothing else was changed, and nothing wakes.
        wakesTheLoop = try database.node.countScheduled() > 0
        throw HandlerFailure.batchRejected(rejection)
    }

    /// Runs `work` in the session's open batch, or in a batch of its own when none is open:
    /// a push outside `begin` … `commit` is committed, and checked, as it ends.
    func inBatch<Result>(_ session: Session, _ work: (BatchJournal) throws -> Result) throws -> Result {
        if session.openBatchDepth > 0, let journal = session.journal {
            return try work(journal)
        }
        try openBatch(session)
        let result: Result
        do {
            guard let journal = session.journal else {
                throw HandlerFailure.malformed(description: "a batch was opened with no journal")
            }
            result = try work(journal)
        } catch {
            // What the work wrote before it threw is committed as a batch of its own would
            // be, and checked: a push that failed part way leaves what it stored, as it did
            // before there were batches.
            try closeBatch(session)
            throw error
        }
        try closeBatch(session)
        return result
    }

    // MARK: - Checkpoints

    func checkpoint(named name: String?) throws -> DaemonResponse {
        let chosen = name ?? Checkpoints.defaultName
        return .checkpoint(name: chosen, contentRoot: try Checkpoints.record(named: chosen))
    }

    func checkpointList() throws -> DaemonResponse {
        .checkpoints(entries: try Checkpoints.all().map { CheckpointRecord(name: $0.name, contentRoot: $0.contentRoot) })
    }

    /// Restores in the session's open batch, or in one of its own, so it is checked at its
    /// commit like any other: a locked folder restored to another root brings its lock back
    /// with it, since the lock is a file of the tree the checkpoint names.
    func restore(named name: String, session: Session) throws -> DaemonResponse {
        let restoration = try inBatch(session) { journal in
            try Checkpoints.restore(named: name, recordingInto: journal)
        }
        return .restored(name: name, contentRoot: restoration.contentRoot, changedPaths: restoration.changedPaths)
    }

    /// A checkpoint verb's failure, by case: a name nobody recorded is answered with the
    /// names that were, and a name that cannot be one is the request's own malformation.
    static func checkpointResponse(for error: CheckpointError) -> ErrorResponse {
        switch error {
        case .notFound(let name, let known):
            return .checkpointNotFound(name: name, known: known)
        case .invalidName:
            return .malformedRequest(description: error.description)
        case .inputRootNotFolded, .unreadableDocument, .missingObject, .unresolvableLink:
            return .nodeError(description: error.description)
        }
    }
}

extension LockExpectation {

    /// The wire form of what the barrier read in the lock.
    init(_ expectation: BatchRejection.Expectation) {
        switch expectation {
        case .contentRoot(let root):
            self = .contentRoot(root)
        case .otherFold(let fold, let root):
            self = .otherFold(fold: fold, contentRoot: root)
        case .unreadable(let error):
            self = .unreadable(line: error.line, problem: error.description)
        }
    }
}

extension DependencyLockError {

    /// The line the error names, when it names one.
    var line: Int? {
        switch self {
        case .unknownKey(_, let line), .repeatedKey(_, let line), .emptyValue(_, let line):
            return line
        case .missingKey, .unknownContentScheme, .malformedArtifact:
            return nil
        }
    }
}
