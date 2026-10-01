//
//  RememberedBaseTests.swift
//  SemelCLITests
//
//  B-136. The base `base <path>` remembers in the Semel home, read at the next launch: the
//  file's text and its refusals, and the choice a launch makes from it without a process.
//

@testable import SemelCLI
import XCTest

final class RememberedBaseTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-remembered-base-tests/\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func parseError(_ text: String) -> RememberedBaseError? {
        do {
            _ = try RememberedBase.parse(text)
            return nil
        } catch {
            return error as? RememberedBaseError
        }
    }

    // MARK: - The text

    func test_aBaseReadsBackAsTheBaseThatWasWritten() throws {
        let remembered = try RememberedBase(directory: "/Users/you/Source/My Repo")

        XCTAssertEqual(try RememberedBase.parse(remembered.text), remembered)
    }

    /// What a person sees who opens the file: what it is, then the one key and the path.
    func test_theTextIsAHeadingThenOneKeyAndValueLine() throws {
        let lines = try RememberedBase(directory: "/repo").text.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].hasPrefix("# "), "got \(lines)")
        XCTAssertTrue(lines[0].contains("base --forget"), "the heading says how to be rid of it, got \(lines[0])")
        XCTAssertEqual(lines[1], "base  /repo")
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(lines.count, 3)
    }

    /// A directory may end in a space; a reader that trimmed it would start elsewhere.
    func test_trailingSpacesInThePathAreKept() throws {
        let remembered = try RememberedBase(directory: "/repo ")

        XCTAssertEqual(try RememberedBase.parse(remembered.text).directory, "/repo ")
    }

    func test_blankLinesCommentsAndIndentationAreFree() throws {
        let text = """

            # hand-edited
              base\t/Users/you/repo

            """

        XCTAssertEqual(try RememberedBase.parse(text).directory, "/Users/you/repo")
    }

    // MARK: - Refusals

    func test_aFileWithNoBaseLineIsRefused() {
        XCTAssertEqual(parseError("# nothing here\n"), .missingKey("base"))
    }

    /// A misspelt key would otherwise be a file that says nothing, read as no base at all.
    func test_anUnknownKeyIsRefusedByItsLine() {
        XCTAssertEqual(parseError("# heading\nbsae /repo\n"), .unknownKey("bsae", line: 2))
    }

    func test_aBaseSaidTwiceIsRefused() {
        XCTAssertEqual(parseError("base /one\nbase /two\n"), .repeatedKey("base", line: 2))
    }

    func test_aBaseWithNoValueIsRefused() {
        XCTAssertEqual(parseError("base\n"), .emptyValue("base", line: 1))
    }

    /// Relative to what? Whichever directory the next `semel` happened to start in.
    func test_aRelativePathIsRefusedInTheFileAndInTheValue() {
        XCTAssertEqual(parseError("base repo\n"), .notAbsolute("repo"))
        XCTAssertThrowsError(try RememberedBase(directory: "repo")) { error in
            XCTAssertEqual(error as? RememberedBaseError, .notAbsolute("repo"))
        }
    }

    func test_aPathWithALineBreakCannotBeRemembered() {
        XCTAssertThrowsError(try RememberedBase(directory: "/one\n/two")) { error in
            XCTAssertEqual(error as? RememberedBaseError, .lineBreakInPath("/one\n/two"))
        }
    }

    // MARK: - On disk

    func test_writeThenReadIsTheSameBaseAndTheHomeIsMadeOnTheWay() throws {
        let file       = scratch.appendingPathComponent("home/\(RememberedBase.fileName)")
        let remembered = try RememberedBase(directory: "/repo")

        try remembered.write(to: file)

        XCTAssertEqual(try RememberedBase.read(from: file), remembered)
    }

    func test_noFileReadsAsNoBase() throws {
        XCTAssertNil(try RememberedBase.read(from: scratch.appendingPathComponent(RememberedBase.fileName)))
    }

    func test_forgetRemovesTheFileAndSaysWhetherThereWasOne() throws {
        let file = scratch.appendingPathComponent(RememberedBase.fileName)
        try RememberedBase(directory: "/repo").write(to: file)

        XCTAssertTrue(try RememberedBase.forget(at: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(try RememberedBase.forget(at: file))
    }

    // MARK: - At launch

    func test_aRememberedDirectoryThatIsThereIsWhereTheLaunchStarts() throws {
        let launch = LaunchBase.choose(saved:            .success(try RememberedBase(directory: "/repo")),
                                       file:             "/home/semel.base",
                                       isDirectory:      { $0 == "/repo" },
                                       currentDirectory: "/cwd")

        XCTAssertEqual(launch, LaunchBase(directory: "/repo", origin: .remembered, passedOver: nil))
        XCTAssertEqual(launch.bannerLines, ["Base: /repo (remembered)"])
    }

    /// Reported on one line and passed over; the file stays, for a volume that comes back.
    func test_aRememberedDirectoryThatIsGoneIsReportedAndTheLaunchStartsHere() throws {
        let launch = LaunchBase.choose(saved:            .success(try RememberedBase(directory: "/gone")),
                                       file:             "/home/semel.base",
                                       isDirectory:      { _ in false },
                                       currentDirectory: "/cwd")

        XCTAssertEqual(launch, LaunchBase(directory: "/cwd", origin: .currentDirectory, passedOver: .directoryGone("/gone")))
        XCTAssertEqual(launch.bannerLines.count, 2)
        XCTAssertTrue(launch.bannerLines[0].contains("/gone"), "got \(launch.bannerLines)")
        XCTAssertEqual(launch.bannerLines[1], "Base: /cwd")
    }

    func test_noRememberedBaseStartsHereWithoutAWord() {
        let launch = LaunchBase.choose(saved:            .success(nil),
                                       file:             "/home/semel.base",
                                       isDirectory:      { _ in XCTFail("nothing to ask of the disk"); return false },
                                       currentDirectory: "/cwd")

        XCTAssertEqual(launch, LaunchBase(directory: "/cwd", origin: .currentDirectory, passedOver: nil))
        XCTAssertEqual(launch.bannerLines, ["Base: /cwd"])
    }

    func test_aFileThatDoesNotReadIsReportedByNameAndTheLaunchStartsHere() {
        let launch = LaunchBase.choose(saved:            .failure(.unknownKey("bsae", line: 2)),
                                       file:             "/home/semel.base",
                                       isDirectory:      { _ in true },
                                       currentDirectory: "/cwd")

        XCTAssertEqual(launch.directory, "/cwd")
        XCTAssertEqual(launch.passedOver, .unreadable(file: "/home/semel.base", .unknownKey("bsae", line: 2)))
        XCTAssertEqual(launch.bannerLines.count, 2)
        XCTAssertTrue(launch.bannerLines[0].contains("/home/semel.base") && launch.bannerLines[0].contains("line 2"),
                      "got \(launch.bannerLines)")
    }

    /// The glue `main` calls: the file and the disk, together.
    func test_atLaunchReadsTheFileAndAsksTheDisk() throws {
        let file = scratch.appendingPathComponent(RememberedBase.fileName)
        let tree = scratch.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try RememberedBase(directory: tree.path).write(to: file)

        XCTAssertEqual(LaunchBase.atLaunch(file: file, currentDirectory: "/cwd").directory, tree.path)

        try FileManager.default.removeItem(at: tree)
        let afterRemoval = LaunchBase.atLaunch(file: file, currentDirectory: "/cwd")
        XCTAssertEqual(afterRemoval.passedOver, .directoryGone(tree.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a gone directory leaves the file as it is")
    }
}
