//
//  LockedFolderEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-146 as a user meets it. `swift-binary-target-app`'s `Greeting` package is given a
//  dependency on a git repository the test makes on disk, so `semel-swift prepare` really
//  vendors it under `Dependencies` and writes its lock. The tree builds; a vendored file is
//  then edited by hand and the next `build` is refused at its push, naming the file, and
//  leaves the export the first build wrote; `prepare` vendors the copy again, and the build
//  after it succeeds.
//
//  The dependency is declared and not imported: an Xcode project's local package has its
//  remote dependencies vendored by `prepare`, and is not yet built against them by the
//  project's converter. The barrier is at the push, whatever reads the folder.
//

import Foundation
import SemelTestSupport
import XCTest

final class LockedFolderEndToEndTests: XCTestCase {

    private var run: EndToEndRun?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
    }

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_aVendoredFileEditedByHandIsRefusedAtThePushAndPrepareThenBuildSucceeds() throws {
        let project = Projects.swiftBinaryTargetApp
        let run = try EndToEndRun(project: project)
        self.run = run
        try run.materialise()
        let app = run.base.appendingPathComponent(project.buildFolder, isDirectory: true)
        let shout = try makeRepository(at: run.root)
        try dependOnShout(app: app, repository: shout)
        try run.configure()

        let vendored = app.appendingPathComponent("Dependencies/Shout/Sources/Shout/Shout.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vendored.path), "prepare vendored the dependency")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Dependencies/Shout.semel-lock").path))

        let server = ServerSession(home: run.root.appendingPathComponent("home", isDirectory: true))
        let out = run.root.appendingPathComponent("out", isDirectory: true)
        try server.start()
        defer { server.killIfRunning() }

        try build(run, project, into: out, server: server, step: "first build")
        let executable = out.appendingPathComponent("Greeter.app/Contents/MacOS/Greeter")
        let firstExport = try Data(contentsOf: executable)

        try "public let shout = \"EDITED\"\n".write(to: vendored, atomically: true, encoding: .utf8)
        let refused = ManagedProcess(executable: EndToEndRun.binary("semel"),
                                     arguments: ["base \(run.base.path)", "build \(project.buildFolder) --into \(out.path)"],
                                     environment: server.environment)
        try refused.start()
        let status = refused.waitForExit(timeout: project.buildTimeout)
        let transcript = refused.outputTail()
        XCTAssertNotEqual(status, 0, transcript)
        let lockedFolder = "input:/\(project.buildFolder)/Dependencies/Shout"
        XCTAssertTrue(transcript.contains("\(lockedFolder) is locked, and the batch changed it without a lock it matches"),
                      transcript)
        XCTAssertTrue(transcript.contains("paths:    \(lockedFolder)/Sources/Shout/Shout.swift"), transcript)
        XCTAssertTrue(transcript.contains("Not built: the push was refused, and nothing was exported."), transcript)
        XCTAssertEqual(try Data(contentsOf: executable), firstExport, "the export is the first build's")

        try EndToEndRun.run("semel-swift", arguments: ["prepare", app.path, "--platform", "macos"],
                            timeout: project.buildTimeout, step: "prepare again")
        XCTAssertEqual(try String(contentsOf: vendored, encoding: .utf8), "public let shout = \"HELLO\"\n",
                       "prepare vendored the copy again, over the edit")
        try build(run, project, into: out, server: server, step: "build after prepare")
        try run.checkProducts(in: out)
        try server.stop()
    }

    // MARK: - The fixture

    private func build(_ run: EndToEndRun, _ project: Project, into out: URL, server: ServerSession, step: String) throws {
        try EndToEndRun.run("semel", arguments: ["base \(run.base.path)", "build \(project.buildFolder) --into \(out.path)"],
                            environment: server.environment, timeout: project.buildTimeout, step: step,
                            serverLog: { server.logTail })
    }

    /// A git repository holding one library, `Shout`, tagged 1.0.0.
    private func makeRepository(at root: URL) throws -> URL {
        let repository = root.appendingPathComponent("repositories/Shout", isDirectory: true)
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(name: "Shout", products: [.library(name: "Shout", targets: ["Shout"])],
                                  targets: [.target(name: "Shout")])

            """, to: repository.appendingPathComponent("Package.swift"))
        try write("public let shout = \"HELLO\"\n", to: repository.appendingPathComponent("Sources/Shout/Shout.swift"))
        try git(["init", "--quiet", "--initial-branch=main"], in: repository)
        try git(["add", "."], in: repository)
        try git(["commit", "--quiet", "-m", "1.0.0"], in: repository)
        try git(["tag", "1.0.0"], in: repository)
        return repository
    }

    /// `Greeting` declares a dependency on `Shout`, which is what `prepare` vendors.
    private func dependOnShout(app: URL, repository: URL) throws {
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "Greeting",
                platforms: [.macOS(.v14)],
                products: [
                    .library(name: "Greeting", targets: ["Greeting"]),
                ],
                dependencies: [
                    .package(url: "\(repository.absoluteString)", exact: "1.0.0"),
                ],
                targets: [
                    .target(name: "Greeting", dependencies: ["Tiny", .product(name: "Shout", package: "Shout")]),
                    .binaryTarget(name: "Tiny", path: "Tiny.xcframework"),
                ]
            )

            """, to: app.appendingPathComponent("Greeting/Package.swift"))
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
