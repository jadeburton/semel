//
//  BuildEngine.swift
//  build_system
//

import Foundation
import GRDB
import DatabaseModels

final class BuildEngine {

    static let shared = try! BuildEngine()

    // MARK: - Constants

    private static let processingBatchSize = 10

    // MARK: - State

    let database: DatabaseLayer

    /// A pending-work flag. Incremented by any caller (any actor/thread) via
    /// `signalWorkAvailable()`. Decremented back to zero at the top of every
    /// drain pass. Using an actor-isolated counter means there is no data race
    /// and no signal can be lost: if two signals arrive while we are draining,
    /// the counter reaches 2, and the loop performs a second drain automatically
    /// before sleeping.
    private let workSignal = WorkSignal()

    // MARK: - Init

    private init(database: DatabaseLayer = try! DatabaseLayer(filePath: "../database124.sqlite")) throws {
        try DefaultTools.setup(toolExecutorRegistry: .instance)
        self.database = database
        // Capture the fully-initialised self before starting the task.
        let engine = self

        Task {
            do {
                try await engine.processLoop()
            } catch {
                // processLoop is not expected to throw; log and surface if it does.
                print("BuildEngine: processLoop terminated with error: \(error)")
            }
        }
    }

    // MARK: - Process loop

    private func processLoop() async throws {
        while true {
            // Drain all available work before sleeping.
            // Keep looping as long as processing produces new scheduled nodes.
            await workSignal.clear()
            do {
                try processAllNodes()
            } catch {
                // Surface DB / processing errors instead of swallowing them.
                print("BuildEngine: error during processAllNodes: \(error)")
            }

            // If a signal arrived while we were processing, drain again immediately
            // instead of sleeping — this is the fix for the "double signal" race.
            guard await workSignal.isPending else {
                await workSignal.wait()
                continue
            }
        }
    }

    // MARK: - Signalling

    /// Safe to call from any actor or thread. A signal will never be lost:
    /// if the engine is currently draining, the pending count is incremented
    /// and the next iteration of processLoop will drain again immediately.
    func signalWorkAvailable() {
        Task { await workSignal.signal() }
    }

    // MARK: - Processing

    func process(_ work: @escaping (_ processingCycle: ProcessingCycle) throws -> Void) throws {
        let processingCycle = try ProcessingCycle(database: database, buildEngine: self)
        try work(processingCycle)
        try processingCycle.endCycle()
    }

    private func processAllNodes() throws {
        while try processSomeNodes() {}
    }

    private func processSomeNodes() throws -> Bool {
        let rawNodes = try database.selectAllScheduledNodes(limit: Self.processingBatchSize)
        guard !rawNodes.isEmpty else { return false }
        for rawNode in rawNodes {
            try processOneNode(rawNode)
        }
        return true
    }

    private func processOneNode(_ rawNode: Node) throws {
        try process { processingCycle in
            try processingCycle.processOneNode(rawNode)
        }
    }
}

// MARK: - WorkSignal

/// An actor that acts as a coalescing, non-lossy signal channel.
///
/// - `signal()` increments a pending counter and resumes any waiting continuation.
/// - `wait()` suspends until the counter is non-zero, then returns.
/// - `clear()` resets the counter to zero (call at the start of each drain pass).
/// - `isPending` returns true if a signal arrived since the last `clear()`.
///
/// Because this is an actor, all mutations are serialised — there is no data race.
private actor WorkSignal {

    private var pendingCount: Int = 0
    private var continuation: CheckedContinuation<Void, Never>?

    /// Increment the pending count and wake any waiting consumer.
    func signal() {
        pendingCount += 1
        continuation?.resume()
        continuation = nil
    }

    /// Returns true if at least one signal has arrived since the last `clear()`.
    var isPending: Bool { pendingCount > 0 }

    /// Reset the pending count to zero. Call at the start of each drain pass.
    func clear() {
        pendingCount = 0
    }

    /// Suspend until at least one signal has been received (non-lossy: if a
    /// signal already arrived before `wait()` is called, returns immediately).
    func wait() async {
        if pendingCount > 0 { return }
        await withCheckedContinuation { cont in
            // If a concurrent signal fires between the check above and here,
            // it will immediately resume the continuation we are about to store.
            self.continuation = cont
        }
    }
}
