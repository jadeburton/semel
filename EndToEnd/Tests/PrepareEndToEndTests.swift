//
//  PrepareEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-138. `semel-swift prepare` as a user runs it, twice and then after a requirement
//  moved, over a package whose dependencies are git repositories the test makes on disk —
//  so SwiftPM really resolves, offline, and the copies and locks are the ones `prepare`
//  really writes. The second run leaves `Dependencies` as it was, byte and date; the third
//  copies the one package whose pin moved.
//

import Foundation
import SemelTestSupport
import XCTest

final class PrepareEndToEndTests: XCTestCase {

    private var root: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        root = try EndToEndEnvironment.newRoot()
    }

    override func tearDown() {
        if let root {
            if EndToEndEnvironment.keepsRoots {
                print("SEMEL_E2E_KEEP=1: kept \(root.path)")
            } else {
                try? FileManager.default.removeItem(at: root)
            }
        }
        super.tearDown()
    }

    func test_aSecondPrepareLeavesDependenciesAsTheyWereAndAMovedPinMovesOnlyItsCopy() throws {
        let root = try XCTUnwrap(self.root)
        let greeting = try makeRepository(named: "Greeting", at: root, releases: ["1.0.0": "Hello", "1.1.0": "Hello again"])
        let shout    = try makeRepository(named: "Shout", at: root, releases: ["1.0.0": "HELLO"])
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try writeApp(in: tree, requiring: [(greeting, "1.0.0"), (shout, "1.0.0")])
        let dependencies = tree.appendingPathComponent("Dependencies", isDirectory: true)

        let first = try prepare(tree)
        XCTAssertTrue(first.contains("Greeting 1.0.0, vendored"), first)
        XCTAssertTrue(first.contains("Shout 1.0.0, vendored"), first)
        let afterFirst = try snapshot(of: dependencies)
        XCTAssertNotNil(afterFirst["Greeting.semel-lock"])

        let second = try prepare(tree)
        XCTAssertTrue(lines(of: second).contains("2 unchanged"), second)
        XCTAssertFalse(second.contains("vendored"), second)
        XCTAssertFalse(second.contains("Locked:"), second)
        XCTAssertEqual(try snapshot(of: dependencies), afterFirst, "a second prepare touches nothing in Dependencies")

        try writeApp(in: tree, requiring: [(greeting, "1.1.0"), (shout, "1.0.0")])
        let third = try prepare(tree)
        XCTAssertTrue(lines(of: third).contains("Greeting 1.0.0 → 1.1.0, re-vendored"), third)
        XCTAssertTrue(lines(of: third).contains("1 unchanged"), third)
        let afterThird = try snapshot(of: dependencies)
        XCTAssertEqual(afterThird.filter { $0.key.hasPrefix("Shout") }, afterFirst.filter { $0.key.hasPrefix("Shout") })
        XCTAssertNotEqual(afterThird["Greeting.semel-lock"], afterFirst["Greeting.semel-lock"])
    }

    // MARK: - The fixture

    /// A git repository holding one library whose source says `text`, committed and tagged
    /// once per release, in version order.
    private func makeRepository(named name: String, at root: URL, releases: [String: String]) throws -> URL {
        let repository = root.appendingPathComponent("repositories/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "--quiet", "--initial-branch=main"], in: repository)
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(name: "\(name)", products: [.library(name: "\(name)", targets: ["\(name)"])],
                                  targets: [.target(name: "\(name)")])

            """, to: repository.appendingPathComponent("Package.swift"))
        for version in releases.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            let text = releases[version] ?? ""
            try write("public let \(name.lowercased()) = \"\(text)\"\n",
                      to: repository.appendingPathComponent("Sources/\(name)/\(name).swift"))
            try git(["add", "."], in: repository)
            try git(["commit", "--quiet", "-m", version], in: repository)
            try git(["tag", version], in: repository)
        }
        return repository
    }

    private func writeApp(in tree: URL, requiring dependencies: [(URL, String)]) throws {
        let packages = dependencies.map { repository, version in
            ".package(url: \"\(repository.absoluteString)\", exact: \"\(version)\")"
        }.joined(separator: ",\n        ")
        let products = dependencies.map { repository, _ in
            let name = repository.lastPathComponent
            return ".product(name: \"\(name)\", package: \"\(name)\")"
        }.joined(separator: ", ")
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "App",
                platforms: [.macOS(.v14)],
                dependencies: [
                    \(packages)
                ],
                targets: [.executableTarget(name: "App", dependencies: [\(products)])]
            )

            """, to: tree.appendingPathComponent("App/Package.swift"))
        try write("print(\"hello\")\n", to: tree.appendingPathComponent("App/Sources/App/main.swift"))
    }

    // MARK: - Running and looking

    private func prepare(_ tree: URL) throws -> String {
        try EndToEndRun.run("semel-swift", arguments: ["prepare", tree.path, "--platform", "macos"],
                            timeout: 300, step: "prepare").output
    }

    private func lines(of output: String) -> [String] {
        output.components(separatedBy: "\n")
    }

    /// Every entry under `folder` by relative path, with a file's bytes and every entry's
    /// modification date: a file copied again has new dates, so an equal snapshot is a
    /// folder nothing wrote into.
    private func snapshot(of folder: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path))
        for case let relativePath as String in enumerator {
            let entry = folder.appendingPathComponent(relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            let bytes = (try? Data(contentsOf: entry)).map { $0.base64EncodedString() } ?? "folder"
            entries[relativePath] = "\(bytes) \(date.timeIntervalSinceReferenceDate)"
        }
        return entries
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String], in repository: URL) throws {
        let process = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/git"),
                                     arguments: ["-c", "user.name=Semel", "-c", "user.email=semel@example.com",
                                                 "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + arguments,
                                     environment: [:], currentDirectory: repository)
        try process.start()
        guard process.waitForExit(timeout: 60) == 0 else {
            throw EndToEndFailure(step: "git \(arguments.joined(separator: " "))", message: "failed",
                                  commandLine: process.commandLine, outputTail: process.outputTail())
        }
    }
}
