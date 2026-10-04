//
//  BatchPlannerTests.swift
//  SemelWatchTests
//
//  B-126. A batch of paths and a disk become the commands a person would type: a push for
//  what exists, an `rm` for what the graph holds and the disk does not.
//

import SemelNodeKit
@testable import SemelWatch
import XCTest

final class BatchPlannerTests: XCTestCase {

    private func plan(_ batch: ChangeBatch, on disk: FakeDisk, held: HeldPaths = HeldPaths(),
                      filter: WatchFilter = WatchFilter(roots: [.empty])) throws -> [String] {
        try BatchPlanner(filter: filter).plan(batch, disk: disk, holdings: held).map(\.description)
    }

    func test_aPathThatExistsIsAPush() throws {
        let disk = FakeDisk(files: ["Sources/App/View.swift", "Sources/App/Model.swift"])

        let commands = try plan(ChangeBatch(changed: ["Sources/App/View.swift"]), on: disk)

        XCTAssertEqual(commands, ["push Sources/App/View.swift"])
    }

    func test_aPathThatDoesNotIsAnRm() throws {
        let disk = FakeDisk(files: ["Sources/App/View.swift"])
        let held = HeldPaths("Sources/App/View.swift", "Sources/App/Old.swift")

        let commands = try plan(ChangeBatch(changed: ["Sources/App/Old.swift"]), on: disk, held: held)

        XCTAssertEqual(commands, ["rm Sources/App/Old.swift"])
    }

    /// An editor's temporary file that came and went inside one quiet interval was never
    /// pushed, and removing it would be an error about nothing.
    func test_aPathTheGraphNeverHeldIsNoCommandWhenItGoes() throws {
        let disk = FakeDisk(files: ["Sources/App/View.swift"])

        let commands = try plan(ChangeBatch(changed: ["Sources/App/4913", "Sources/App/View.swift"]), on: disk)

        XCTAssertEqual(commands, ["push Sources/App/View.swift"])
    }

    /// The paths of a folder that went are one `rm` of the folder, which takes everything
    /// below it — however many of its paths, and itself, the stream reported.
    func test_aFolderThatDisappearedIsOneRm() throws {
        let disk = FakeDisk(files: ["Sources/App/View.swift"])
        let held = HeldPaths("Sources/Old", "Sources/Old/a.swift", "Sources/Old/Deep/b.swift")

        let commands = try plan(ChangeBatch(changed: ["Sources/Old/a.swift", "Sources/Old/Deep/b.swift", "Sources/Old"]),
                                on: disk, held: held)

        XCTAssertEqual(commands, ["rm Sources/Old"])
    }

    /// FSEvents' must-scan-subdirectories: what changed below is not known path by path, so
    /// the subtree is pushed whole — one push, which sends only what the graph lacks.
    func test_aMustRescanFlagBecomesAPushOfTheSubtree() throws {
        let disk = FakeDisk(files: ["Sources/App/View.swift", "Sources/App/Model.swift", "Sources/Lib/Lib.swift"])

        let commands = try plan(ChangeBatch(changed: ["Sources/App/View.swift"], rescanned: ["Sources"]), on: disk)

        XCTAssertEqual(commands, ["push Sources"], "the changed file is inside the folder pushed whole")
    }

    /// A folder moved into the tree is reported as the folder alone: what is on disk below
    /// it is pushed with it.
    func test_aFolderThatAppearedIsPushedWhole() throws {
        let disk = FakeDisk(files: ["Sources/New/a.swift", "Sources/New/b.swift"], folders: ["Sources/Empty"])

        let commands = try plan(ChangeBatch(changed: ["Sources/New", "Sources/Empty"]), on: disk)

        XCTAssertEqual(commands, ["push Sources/Empty", "push Sources/New"])
    }

    /// A rename is a removal and a push, the removal first.
    func test_aRenameIsARemovalAndAPush() throws {
        let disk = FakeDisk(files: ["Sources/Renamed.swift"])
        let held = HeldPaths("Sources/Original.swift")

        let commands = try plan(ChangeBatch(changed: ["Sources/Original.swift", "Sources/Renamed.swift"]), on: disk, held: held)

        XCTAssertEqual(commands, ["rm Sources/Original.swift", "push Sources/Renamed.swift"])
    }

    /// A folder only part of which the filter admits is pushed file by file; one it admits
    /// whole is one push.
    func test_aFilterThatTakesPartOfAFolderPushesItFileByFile() throws {
        let disk = FakeDisk(files: ["src/a.c", "src/test_a.c", "src/a.h", "lib/b.c"])
        let filter = WatchFilter(roots: [.empty], only: ["**/*.c"], except: ["**/test_*.c"])

        let commands = try plan(ChangeBatch(rescanned: ["src", "lib"]), on: disk, filter: filter)

        XCTAssertEqual(commands, ["push lib", "push src/a.c"])
    }

    /// `push .` names nothing, so the base is planned by its children — leaving out the
    /// folder `build` exports into.
    func test_theBaseIsPushedByItsChildren() throws {
        let disk = FakeDisk(files: ["c/hello.c", "semel.machine.config", "semel-out/c/hello"])

        let commands = try BatchPlanner(filter: WatchFilter(roots: [.empty]))
            .planMirroring(folders: [.empty], disk: disk, holdings: HeldPaths()).commands.map(\.description)

        XCTAssertEqual(commands, ["push c", "push semel.machine.config"])
    }

    /// A dot-named file is pushed when the graph holds it, pushed once by its name — and
    /// otherwise left where it is, as a push of its folder leaves it.
    func test_aDotNamedFileIsPushedOnlyWhenTheGraphHoldsIt() throws {
        let disk = FakeDisk(files: ["app/.all-contributorsrc", "app/.DS_Store", "app/main.swift"])
        let held = HeldPaths("app/.all-contributorsrc")

        let commands = try plan(ChangeBatch(changed: ["app/.all-contributorsrc", "app/.DS_Store"]), on: disk, held: held)

        XCTAssertEqual(commands, ["push app/.all-contributorsrc"])
    }

    /// Nothing is planned outside the watched folders, under a dot-named folder, or where
    /// exports go; nothing at all is asked of the graph for them.
    func test_whatTheFilterExceptsIsNeverPlannedNorAskedAbout() throws {
        let disk = FakeDisk(files: ["Packages/App/a.swift", "Docs/index.md", ".git/index", "out/App"])
        let held = HeldPaths()
        let filter = WatchFilter(roots: ["Packages"], exportDestination: "out")

        let commands = try plan(ChangeBatch(changed: ["Docs/index.md", ".git/index", "out/App", "Packages/App/a.swift"]),
                                on: disk, held: held, filter: filter)

        XCTAssertEqual(commands, ["push Packages/App/a.swift"])
        XCTAssertEqual(held.asked, [])
    }

    /// A watched folder renamed away is reported as the folder above it moving; what it
    /// comes to is the watched folder gone, and removed whole.
    func test_aWatchedFolderThatWentIsRemovedWhole() throws {
        let disk = FakeDisk(files: ["Other/a.swift"])
        let held = HeldPaths("Packages", "Packages/App/a.swift")

        let commands = try plan(ChangeBatch(changed: ["Packages/App/a.swift"]), on: disk, held: held,
                                filter: WatchFilter(roots: ["Packages"]))

        XCTAssertEqual(commands, ["rm Packages"])
    }
}
