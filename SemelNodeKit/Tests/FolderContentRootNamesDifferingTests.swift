//
//  FolderContentRootNamesDifferingTests.swift
//  SemelNodeKitTests
//
//  B-164. A lock that refuses a batch names what the folder lacks against the lock's tree
//  and what it holds that the tree does not, read from the two trees' documents together.
//

@testable import SemelNodeKit
import XCTest

final class FolderContentRootNamesDifferingTests: XCTestCase {

    private var userStore: DataObjectStore!

    /// A store of this test's own: the documents are interned, and the user's store is not
    /// the place for a test's bytes.
    override func setUpWithError() throws {
        try super.setUpWithError()
        userStore = DataObjectStore.shared
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-names-differing-tests/\(UUID().uuidString)", isDirectory: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: root)
    }

    override func tearDown() {
        DataObjectStore.shared = userStore
        super.tearDown()
    }

    private func folder(_ lines: [FolderContentRoot.Line]) throws -> DataObjectHash {
        try FolderContentRoot.document(of: lines).intern()
    }

    private func file(_ name: String, _ hash: String = "aa11") -> FolderContentRoot.Line {
        (name, .file, .file(hash: hash, mode: 0o644))
    }

    func test_theNamesOnEachSideOnlyAreListedAndAFolderOnOneSideOnce() throws {
        let shared   = try folder([file("Chart.swift")])
        let extra    = try folder([file("One.swift"), file("Two.swift")])
        let lockSide = try folder([file("Edited.swift", "bb22")])
        let pushSide = try folder([file("Edited.swift", "cc33"), file("New.swift")])
        let lock = try folder([file("LICENSE"), file("Package.swift"), ("Sources", .folder, .hash(shared)),
                               ("Nested", .folder, .hash(lockSide)), ("Snapshots", .folder, .hash(shared))])
        let pushed = try folder([file("Package.swift"), ("Sources", .folder, .hash(shared)),
                                 ("Nested", .folder, .hash(pushSide)), ("Extra", .folder, .hash(extra))])

        let names = try XCTUnwrap(try FolderContentRoot.namesDiffering(expected: lock, found: pushed))

        XCTAssertEqual(names.onlyExpected, ["LICENSE", "Snapshots/"])
        XCTAssertEqual(names.onlyFound, ["Extra/", "Nested/New.swift"])
    }

    func test_aFolderThatIsNotThereLacksEveryName() throws {
        let lock = try folder([file("LICENSE"), file("Package.swift")])

        let names = try XCTUnwrap(try FolderContentRoot.namesDiffering(expected: lock, found: nil))

        XCTAssertEqual(names, NamesDiffering(onlyExpected: ["LICENSE", "Package.swift"], onlyFound: []))
    }

    /// A lock's root names documents the store holds only once the engine has folded that
    /// tree; one it does not hold cannot be compared, which is not the same as no difference.
    func test_aRootTheStoreDoesNotHoldIsNotCompared() throws {
        let pushed = try folder([file("Package.swift")])

        XCTAssertNil(try FolderContentRoot.namesDiffering(expected: String(repeating: "0", count: 64), found: pushed))
    }
}
