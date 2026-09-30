//
//  FolderContentRootOnDiskTests.swift
//  SemelNodeKitTests
//
//  B-06. `semel-swift prepare` records a vendored folder's content root from the disk, and
//  the engine publishes one for the pushed copy; a lock is only worth something if the two
//  agree. The format is shared by construction, so these pin *what* the disk fold reads:
//  what a push would push, and nothing else. `SemelCore`'s `DependencyLockFoldTests` pushes
//  a tree through the engine and compares.
//

@testable import SemelNodeKit
import XCTest

final class FolderContentRootOnDiskTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-content-root-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        // Fixed, so the expected lines do not depend on the runner's umask.
        chmod(url.path, 0o644)
    }

    /// A file's line as the engine folds it, pushed with the mode `write` gives it.
    private func file(_ text: String) -> FolderChildContent {
        .file(hash: hash(text), mode: 0o644)
    }

    private func folder(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: true)
    }

    private func hash(_ text: String) -> String {
        Sha256.hash(Data(text.utf8))
    }

    // MARK: - The fold

    /// The same document the engine folds, line for line: a file carries its bytes' hash,
    /// a subfolder its own root, and an empty file the empty hash the store gives it.
    func test_theRootIsTheHashOfTheDocumentTheEngineFolds() throws {
        try write("Pkg/Package.swift", "// swift-tools-version: 5.9\n")
        try write("Pkg/empty.txt", "")
        try write("Pkg/Sources/Lib/Lib.swift", "public let answer = 42\n")

        let lib = FolderContentRoot.document(of: [("Lib.swift", .file, file("public let answer = 42\n"))])
        let sources = FolderContentRoot.document(of: [("Lib", .folder, .hash(hash(lib)))])
        let package = FolderContentRoot.document(of: [
            ("Package.swift", .file,   file("// swift-tools-version: 5.9\n")),
            ("empty.txt",     .file,   file("")),
            ("Sources",       .folder, .hash(hash(sources))),
        ])

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), hash(package))
    }

    func test_aChangeAnywhereBelowMovesTheRoot() throws {
        try write("Pkg/Sources/Lib/Lib.swift", "let one = 1\n")
        let before = try FolderContentRoot.root(ofFolderAt: folder("Pkg"))

        try write("Pkg/Sources/Lib/Lib.swift", "let one = 2\n")

        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), before)
    }

    /// B-132. A file made executable is a different tree, and a push comparing roots would
    /// never send the change if the root did not move with it.
    func test_aModeChangeMovesTheRoot() throws {
        try write("Pkg/run.sh", "echo\n")
        let before = try FolderContentRoot.root(ofFolderAt: folder("Pkg"))

        chmod(folder("Pkg/run.sh").path, 0o755)

        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), before)
        XCTAssertTrue(FolderContentRoot.document(of: [("run.sh", .file, .file(hash: hash("echo\n"), mode: 0o755))])
                        .contains("file\thash \(hash("echo\n")) mode 755\t6\trun.sh\n"))
    }

    /// Not qualified by where the folder is, so a lock survives the dependency being moved.
    func test_theSameTreeAtTwoPathsHasOneRoot() throws {
        try write("One/Pkg/Sources/A.swift", "a\n")
        try write("Two/Elsewhere/Sources/A.swift", "a\n")

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: folder("One/Pkg")),
                       try FolderContentRoot.root(ofFolderAt: folder("Two/Elsewhere")))
    }

    // MARK: - Only what a push pushes

    /// A push leaves out every name starting with a dot, so the engine never sees a copied
    /// checkout's `.github` or `.gitignore`; folding them here would lock a tree no build
    /// is given.
    func test_aHiddenFileOrFolderDoesNotMoveTheRoot() throws {
        try write("Pkg/Package.swift", "p\n")
        let before = try FolderContentRoot.root(ofFolderAt: folder("Pkg"))

        try write("Pkg/.gitignore", ".build\n")
        try write("Pkg/.github/workflows/ci.yml", "on: push\n")

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), before)
    }

    /// A push creates a folder only on the way to a file, so a folder with no file under it
    /// — empty, or holding only hidden ones — has no node in the graph and no line here.
    func test_aFolderWithNoFileBelowItDoesNotMoveTheRoot() throws {
        try write("Pkg/Package.swift", "p\n")
        let before = try FolderContentRoot.root(ofFolderAt: folder("Pkg"))

        try FileManager.default.createDirectory(at: folder("Pkg/Empty/Deeper"), withIntermediateDirectories: true)
        try write("Pkg/OnlyHidden/.keep", "")

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), before)
    }

    // MARK: - Links (B-77)

    /// A link inside its folder, to a file or to a folder, is a `link` line holding its
    /// target, and nothing is read through it; what it names is folded where it is. A link
    /// out of its folder is followed, and folds as the file it names.
    func test_aLinkInsideItsFolderFoldsAsItsTarget() throws {
        try write("Fw/Versions/A/Tiny", "binary")
        try write("outside.h", "outside")
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: folder("Fw/Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: folder("Fw/Tiny").path, withDestinationPath: "Versions/Current/Tiny")
        try fileManager.createSymbolicLink(atPath: folder("Fw/Outside.h").path, withDestinationPath: "../outside.h")

        let version  = FolderContentRoot.document(of: [("Tiny", .file, file("binary"))])
        let versions = FolderContentRoot.document(of: [("A",       .folder, .hash(hash(version))),
                                                       ("Current", .link,   .symbolicLinkTarget("A"))])
        let framework = FolderContentRoot.document(of: [("Outside.h", .file,   file("outside")),
                                                        ("Tiny",      .link,   .symbolicLinkTarget("Versions/Current/Tiny")),
                                                        ("Versions",  .folder, .hash(hash(versions)))])

        XCTAssertEqual(try FolderContentRoot.root(ofFolderAt: folder("Fw")), hash(framework))
        XCTAssertTrue(framework.contains("link\ttarget 21 Versions/Current/Tiny\t4\tTiny\n"), framework)
    }

    /// Retargeting a link moves the root though nothing it could name did, and a link is
    /// not the copy of what it names.
    func test_aLinkIsNotTheCopyOfWhatItNames() throws {
        try write("Pkg/Real.txt", "same")
        try write("Pkg/Other.txt", "same")
        try FileManager.default.createSymbolicLink(atPath: folder("Pkg/Alias.txt").path, withDestinationPath: "Real.txt")
        let linked = try FolderContentRoot.root(ofFolderAt: folder("Pkg"))

        try FileManager.default.removeItem(at: folder("Pkg/Alias.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder("Pkg/Alias.txt").path, withDestinationPath: "Other.txt")
        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), linked)

        try FileManager.default.removeItem(at: folder("Pkg/Alias.txt"))
        try write("Pkg/Alias.txt", "same")
        XCTAssertNotEqual(try FolderContentRoot.root(ofFolderAt: folder("Pkg")), linked)
    }
}
