//
//  DatabaseLayerTransactionPerStepTests.swift
//  SemelCoreTests
//
//  `withTransactionPerStep`: one commit around a run of steps that keep the boundaries
//  their own transactions would have drawn. What a batch of pushed files is recorded in,
//  so that a file the graph refuses leaves what it left when it was a transaction of its
//  own, and the files around it are recorded all the same.
//
//  `SemelDatabaseModels` has no test target of its own, so its tests live in this one.
//

@testable import SemelCore
import SemelDatabaseModels
import XCTest

final class DatabaseLayerTransactionPerStepTests: SemelCoreTestCase {

    private var database: DatabaseLayer!

    private struct StepFailure: Error {}

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try DatabaseLayer()
    }

    override func tearDown() {
        database = nil
        super.tearDown()
    }

    private func insertLiteral() throws {
        _ = try database.node.insert(NodeRecord(kind: SettingsLiteral.kind))
    }

    private func literalCount() throws -> Int {
        try database.node.select(kind: SettingsLiteral.kind).count
    }

    func test_aStepThatThrowsUndoesItsOwnWritesAndTheStepsAroundItStand() throws {
        try database.withTransactionPerStep {
            try database.withTransaction { try insertLiteral() }
            XCTAssertThrowsError(try database.withTransaction {
                try insertLiteral()
                try insertLiteral()
                throw StepFailure()
            })
            try database.withTransaction { try insertLiteral() }
        }

        XCTAssertEqual(try literalCount(), 2, "the step that threw left nothing; the two around it are committed")
    }

    /// One level of savepoints, the boundary a transaction of its own drew: a transaction
    /// inside a step takes part in the step, as one inside any transaction does, so what it
    /// wrote stands or falls with the step.
    func test_aTransactionInsideAStepTakesPartInTheStep() throws {
        try database.withTransactionPerStep {
            try database.withTransaction {
                try insertLiteral()
                XCTAssertThrowsError(try database.withTransaction {
                    try insertLiteral()
                    throw StepFailure()
                })
            }
            XCTAssertThrowsError(try database.withTransaction {
                try database.withTransaction { try insertLiteral() }
                throw StepFailure()
            })
        }

        XCTAssertEqual(try literalCount(), 2,
                       "the first step caught its inner failure and kept both writes; the second threw and kept none")
    }

    /// A write outside any step is part of the one transaction, and stands.
    func test_aWriteOutsideAStepIsPartOfTheWhole() throws {
        try database.withTransactionPerStep {
            try insertLiteral()
            XCTAssertThrowsError(try database.withTransaction {
                try insertLiteral()
                throw StepFailure()
            })
        }

        XCTAssertEqual(try literalCount(), 1)
    }

    /// What escapes the whole is not a step's failure, and nothing of the run is kept.
    func test_aFailureOutOfTheWholeUndoesEveryStep() throws {
        XCTAssertThrowsError(try database.withTransactionPerStep {
            try database.withTransaction { try insertLiteral() }
            try insertLiteral()
            throw StepFailure()
        })

        XCTAssertEqual(try literalCount(), 0)
    }

    /// Inside a transaction already, it takes part in that one, as `withTransaction` does,
    /// and its steps do too.
    func test_insideATransactionItTakesPartInIt() throws {
        XCTAssertThrowsError(try database.withTransaction {
            try database.withTransactionPerStep {
                try database.withTransaction { try insertLiteral() }
            }
            throw StepFailure()
        })

        XCTAssertEqual(try literalCount(), 0)
    }

    /// The steps see one another's writes, as transactions committed one after another
    /// would.
    func test_aStepReadsWhatTheStepsBeforeItWrote() throws {
        var counts: [Int] = []
        try database.withTransactionPerStep {
            for _ in 0..<3 {
                try database.withTransaction {
                    try insertLiteral()
                    counts.append(try literalCount())
                }
            }
        }

        XCTAssertEqual(counts, [1, 2, 3])
    }
}
