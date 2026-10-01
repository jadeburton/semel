//
//  WatchFilterTests.swift
//  SemelWatchTests
//
//  B-126. What a watcher pushes is what a push would push, narrowed by `--only` and
//  `--except` and never widened.
//

import Foundation
import SemelNodeKit
@testable import SemelCLI
@testable import SemelWatch
import XCTest

final class WatchFilterTests: XCTestCase {

    private var directory: URL?

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - The lister's rule

    /// A dot-named folder is never walked into, at any depth; a dot-named file is matched by
    /// no wildcard, `**/*` included, and is a candidate only when named exactly or already
    /// held — the rule `push` follows (B-77 item 5).
    func test_dotNamesAtAnyLevelAreNeverCandidates() {
        let filter = WatchFilter(roots: [.empty])

        XCTAssertFalse(filter.admits(".git/config"))
        XCTAssertFalse(filter.admits("src/.build/debug/a.o"))
        XCTAssertFalse(filter.admits("src/.env"), "no wildcard selects a dot-named file")
        XCTAssertTrue(filter.admits("src/.env", isHeld: true), "a dot-named file the graph holds is a source")
        XCTAssertFalse(filter.admits(".git/config", isHeld: true), "nothing below a dot-named folder, held or not")

        let naming = WatchFilter(roots: [.empty], only: ["**/*", "app/.all-contributorsrc"])
        XCTAssertTrue(naming.admits("app/.all-contributorsrc"))
        XCTAssertFalse(naming.admits("app/.other"))
    }

    /// The same, read from a real disk through the lister a push uses: a file under a
    /// dot-named folder is not there to a push, a dot-named file named exactly is.
    func test_aDotNamedFolderIsNotThereToAPushAndADotNamedFileNamedExactlyIs() throws {
        let base = try makeDirectory()
        try write("[core]", to: base, at: ".git/config")
        try write("KEY=1", to: base, at: "src/.env")
        let disk = ExternalFileSystemLister(rootDirectoryPath: base.path)

        XCTAssertNil(WatchFilter.entry(at: ".git/config", on: disk))
        XCTAssertNil(WatchFilter.entry(at: ".git", on: disk), "a dot-named folder is no entry")
        XCTAssertEqual(WatchFilter.entry(at: "src/.env", on: disk)?.kind, .file)
    }

    /// A link to a folder above itself would walk the same tree without end, so the lister
    /// leaves it out, and nothing reported through it is a candidate; a link elsewhere is
    /// followed, as a push follows it.
    func test_aLinkAboveItselfIsNotFollowed() throws {
        let base = try makeDirectory()
        try write("int a;", to: base, at: "src/a.c")
        try write("int x;", to: base, at: "elsewhere/x.c")
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("src/loop").path,
                                                   withDestinationPath: "..")
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("src/vendor").path,
                                                   withDestinationPath: "../elsewhere")
        let disk = ExternalFileSystemLister(rootDirectoryPath: base.path)

        XCTAssertNil(WatchFilter.entry(at: "src/loop", on: disk))
        XCTAssertNil(WatchFilter.entry(at: "src/loop/src/a.c", on: disk))
        XCTAssertEqual(WatchFilter.entry(at: "src/vendor/x.c", on: disk)?.kind, .file)
    }

    // MARK: - --only and --except

    /// `--only` and `--except` read as `{f: <src/**/*.c> except <src/test_*.c>, …}` reads
    /// (B-123): a path is pushed when some `--only` matches it and no `--except` does.
    func test_onlyAndExceptComposeAsTheForEachsItemsAndExcept() {
        let filter = WatchFilter(roots: [.empty],
                                 only: ["src/**/*.c", "src/**/*.h"],
                                 except: ["src/test_*.c", "src/**/lua.c"])

        XCTAssertTrue(filter.admits("src/a.c"))
        XCTAssertTrue(filter.admits("src/deep/b.c"), "`**` matches any number of folders")
        XCTAssertTrue(filter.admits("src/deep/b.h"), "any `--only` admits")
        XCTAssertFalse(filter.admits("src/test_a.c"), "an `--except` takes it back")
        XCTAssertFalse(filter.admits("src/lib/lua.c"))
        XCTAssertFalse(filter.admits("src/README.md"), "no `--only` matches")
        XCTAssertFalse(filter.admits("docs/a.c"), "`--only` is relative to the base")
    }

    /// No `--only` is `**/*`: every path under the watched folders, and none outside them.
    func test_withoutOnlyEveryPathUnderAWatchedFolderIsPushed() {
        let filter = WatchFilter(roots: ["Packages"])

        XCTAssertTrue(filter.admits("Packages/App/Sources/View.swift"))
        XCTAssertTrue(filter.admits("Packages/Dependencies/Lib/Package.swift"), "a re-vendored copy is a change")
        XCTAssertFalse(filter.admits("Docs/index.md"), "not under a watched folder")
        XCTAssertTrue(filter.admitsEverything)
    }

    /// Whatever the flags say, what `build` and the watcher export into is never pushed:
    /// a watcher that pushed what it exported would build forever.
    func test_theExportDestinationAndSemelOutAreExceptedWhateverTheFlagsSay() {
        let filter = WatchFilter(roots: [.empty], only: ["**/*", "out/**", "semel-out/**"], exportDestination: "out")

        XCTAssertFalse(filter.admits("out/hello"))
        XCTAssertFalse(filter.admits("semel-out/c/hello"))
        XCTAssertFalse(filter.mayAdmitBelow("out"))
        XCTAssertTrue(filter.admits("outside/hello"), "a prefix of a name is not the folder")
        XCTAssertEqual(filter.alwaysExcepted, ["semel-out", "out"])
    }

    /// The folder the watcher always excepts is the one `build` exports into by default.
    func test_semelOutIsWhereBuildExportsByDefault() {
        XCTAssertEqual(WatchFilter.defaultExportFolder.string, CommandInterpreter.defaultExportFolder)
    }

    /// A folder is walked only when some `--only` can reach below it.
    func test_aFolderNoOnlyCanReachIsNotWalked() {
        let filter = WatchFilter(roots: [.empty], only: ["src/*.c"])

        XCTAssertTrue(filter.mayAdmitBelow("src"))
        XCTAssertFalse(filter.mayAdmitBelow("src/deep"))
        XCTAssertFalse(filter.mayAdmitBelow("docs"))
        XCTAssertFalse(filter.admitsEverything)
    }

    /// A source the follow pushed from outside the watched folders is watched from then on.
    func test_aFollowedPathIsWatched() {
        var filter = WatchFilter(roots: ["c"])
        XCTAssertFalse(filter.admits("semel.machine.config"))

        filter.watch("semel.machine.config")

        XCTAssertTrue(filter.admits("semel.machine.config"))
        XCTAssertFalse(filter.admits("other.config"))
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let made = try makeTemporaryDirectory()
        directory = made
        return made
    }

    private func write(_ text: String, to base: URL, at path: String) throws {
        let file = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
