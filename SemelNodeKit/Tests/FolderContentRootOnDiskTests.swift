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

        let lib = FolderContentRoot.document(of: [("Lib.swift", .file, .hash(hash("public let answer = 42\n")))])
        let sources = FolderContentRoot.document(of: [("Lib", .folder, .hash(hash(lib)))])
        let package = FolderContentRoot.document(of: [
            ("Package.swift", .file,   .hash(hash("// swift-tools-version: 5.9\n"))),
            ("empty.txt",     .file,   .hash("")),
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
}
