//
//  ExternalFileSystemListerTests.swift
//  SemelNodeKitTests
//

@testable import SemelNodeKit
import Foundation
import XCTest

/// The lister a push walks the disk with. A real package tree has symbolic links in it —
/// RevenueCat keeps a target's sources behind one, and a test fixture of its links back
/// to the package root — so following links is required and following a cycle is fatal:
/// the walk grows without end until memory runs out.
final class ExternalFileSystemListerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lister-tests/\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("pkg/Sources"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("pkg/Tests/Deep"), withIntermediateDirectories: true)
        try "swift".write(to: root.appendingPathComponent("pkg/Sources/A.swift"), atomically: true, encoding: .utf8)
        // A link beside the sources, as RevenueCat's CustomEntitlementComputation is.
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("pkg/Alias").path, withDestinationPath: "Sources")
        // A link back to the package root, as its Carthage fixture is.
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("pkg/Tests/Deep/root").path, withDestinationPath: "../../")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func test_followsALinkBesideTheSourcesButNotOneBackUpTheTree() throws {
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: root.path))

        let paths = try matcher.findAllMatching(pathOrWildcard: "pkg/**/*").map(\.path.string).sorted()

        XCTAssertTrue(paths.contains("pkg/Sources/A.swift"), "\(paths)")
        XCTAssertTrue(paths.contains("pkg/Alias/A.swift"), "a link to a sibling is a folder of its own: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/root") }, "a link up the tree is a cycle, never entered: \(paths)")
    }
}
