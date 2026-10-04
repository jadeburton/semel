//
//  LaunchReconciliationTests.swift
//  SemelWatchTests
//
//  The initial batch mirrors the watched folders: what the graph holds below them and the
//  disk no longer has is removed in the same batch that pushes them, since a push only
//  adds — and what the filter excepts is left, however the disk stands.
//

import SemelNodeKit
@testable import SemelWatch
import XCTest

final class LaunchReconciliationTests: XCTestCase {

    private func mirror(_ folders: [Path], on disk: FakeDisk, held: HeldPaths,
                        only: [String] = [], except: [String] = []) throws -> MirrorPlan {
        try BatchPlanner(filter: WatchFilter(roots: folders, only: only, except: except))
            .planMirroring(folders: folders, disk: disk, holdings: held)
    }

    /// Every held path the disk lacks goes in one `rm` — the batch issues the removals
    /// together — before the push of the folder.
    func test_aPathTheGraphHoldsAndTheDiskLacksIsRemoved() throws {
        let disk = FakeDisk(files: ["src/a.c"])
        let held = HeldPaths("src/a.c", "src/b.c", "src/old/c.c", "src/old/d.c")

        let plan = try mirror(["src"], on: disk, held: held)

        XCTAssertEqual(plan.commands.map(\.description), ["rm src/b.c", "rm src/old", "push src"])
        XCTAssertEqual(plan.removedCount, 3)
        XCTAssertEqual(plan.exceptedCount, 0)
    }

    /// A narrowing filter is not a request to delete: a held path it excepts stays, and a
    /// folder holding one is removed around it rather than whole.
    func test_aPathTheFilterExceptsIsNotRemoved() throws {
        let disk = FakeDisk(files: ["src/a.c"])
        let held = HeldPaths("src/a.c", "src/b.h", "src/old/c.c", "src/old/c.h")

        let plan = try mirror(["src"], on: disk, held: held, only: ["**/*.c"])

        XCTAssertEqual(plan.commands.map(\.description), ["rm src/old/c.c", "push src"])
        XCTAssertEqual(plan.removedCount, 1)
        XCTAssertEqual(plan.exceptedCount, 2)
    }

    /// A dot-named file is matched by no wildcard, but the graph holding it makes it a
    /// source, so its absence from the disk is a removal like any other.
    func test_aDotNamedFileTheGraphHoldsAndTheDiskLacksIsRemoved() throws {
        let disk = FakeDisk(files: ["app/main.swift", "app/.kept"])
        let held = HeldPaths("app/main.swift", "app/.kept", "app/.all-contributorsrc")

        let plan = try mirror(["app"], on: disk, held: held)

        XCTAssertEqual(plan.commands.map(\.description), ["rm app/.all-contributorsrc", "push app"])
        XCTAssertEqual(plan.removedCount, 1)
    }

    /// A disk that has everything the graph holds needs no `rm` at all.
    func test_nothingMissingYieldsNoRm() throws {
        let disk = FakeDisk(files: ["src/a.c", "src/lib/b.c"])
        let held = HeldPaths("src/a.c", "src/lib/b.c")

        let plan = try mirror(["src"], on: disk, held: held)

        XCTAssertEqual(plan.commands.map(\.description), ["push src"])
        XCTAssertEqual(plan.removedCount, 0)
        XCTAssertEqual(plan.exceptedCount, 0)
    }

    /// Only the watched folders are compared: a source pushed from outside them — the
    /// follow's machine file beside the project — is not this watcher's to delete, nor is
    /// anything else beside them.
    func test_nothingOutsideTheWatchedFoldersIsRemoved() throws {
        let disk = FakeDisk(files: ["c/hello.c"])
        let held = HeldPaths("c/hello.c", "semel.machine.config", "other/x.c")

        let plan = try mirror(["c"], on: disk, held: held)

        XCTAssertEqual(plan.commands.map(\.description), ["push c"])
        XCTAssertEqual(plan.exceptedCount, 0)
    }

    /// A watched folder gone from disk whole is one `rm` of the folder.
    func test_aWatchedFolderGoneFromDiskIsRemovedWhole() throws {
        let disk = FakeDisk(files: ["other/a.c"])
        let held = HeldPaths("src/a.c", "src/lib/b.c")

        let plan = try mirror(["src"], on: disk, held: held)

        XCTAssertEqual(plan.commands.map(\.description), ["rm src"])
        XCTAssertEqual(plan.removedCount, 2)
    }
}
