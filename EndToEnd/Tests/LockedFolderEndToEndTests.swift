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
        let lockedFolder = "\(project.buildFolder)/Dependencies/Shout"
        XCTAssertTrue(transcript.contains("\(lockedFolder) is locked, and the batch changes it without a lock it matches"),
                      transcript)
        XCTAssertTrue(transcript.contains("  paths: \(lockedFolder)/Sources/Shout/Shout.swift"), transcript)
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

    // MARK: - A refusal larger than a reply (B-161)

    /// Twenty thousand files pushed into a locked folder whose lock they do not match, with
    /// one unlocked file beside them: the barrier refuses the batch, and the refusal names
    /// more paths than one reply could carry. It reaches the client bounded — the first
    /// fifty paths and a count of the rest, of which the client prints five and counts the
    /// others — says that `input:` is as it was, and leaves no
    /// batch open, unbatched and under `begin` … `commit` alike. The push never says the
    /// files were pushed, and every error starts with the client's mark.
    func test_aRefusalOfTwentyThousandPathsReachesTheClientCountedAndClosesTheBatch() throws {
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        let root = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base    = root.appendingPathComponent("base", isDirectory: true)
        let package = "tree/Packages/Dependencies/FooPackage"
        let count   = 20_000
        for index in 0..<count {
            try write("let value\(index) = \(index)\n",
                      to: base.appendingPathComponent("\(package)/Sources/FooPackage/Folder\(index / 200)/File\(index).swift"))
        }
        try write("print(1)\n", to: base.appendingPathComponent("tree/App/main.swift"))
        try write("content  sha256:\(String(repeating: "0", count: 64))\nfold     semel-folder-content-root 4\n",
                  to: base.appendingPathComponent("\(package).semel-lock"))

        let server = ServerSession(home: root.appendingPathComponent("home", isDirectory: true))
        try server.start()
        defer { server.killIfRunning() }

        let unbatched = try semel(["base \(base.path)", "push tree", "ls"], server: server)
        let batched   = try semel(["base \(base.path)", "begin", "push tree", "commit", "ls", "commit"], server: server)
        for transcript in [unbatched, batched] {
            XCTAssertTrue(transcript.contains("\(package) is locked, and the batch changes it without a lock it matches: "
                                              + "nothing of the batch is committed"), transcript)
            // The batch's changed paths below the folder: the files, their folders, and the lock.
            // The rejection carries fifty and counts the rest; the client prints five and
            // counts the other forty-five with them, so the count is every path but five.
            let changed   = count + count / 200 + 4
            let pathsLine = try XCTUnwrap(transcript.split(separator: "\n").first { $0.hasPrefix("  paths: ") })
            XCTAssertTrue(pathsLine.hasSuffix(" and \(changed - 5) more"), String(pathsLine))
            let named = pathsLine.dropFirst("  paths: ".count).components(separatedBy: " and ").first ?? ""
            XCTAssertEqual(named.components(separatedBy: ", "),
                           [package, "\(package).semel-lock", "\(package)/Sources", "\(package)/Sources/FooPackage",
                            "\(package)/Sources/FooPackage/Folder0"], String(pathsLine))
            XCTAssertTrue(transcript.contains("  input: as it was before the batch; nothing the batch pushed or removed is there"),
                          transcript)
            XCTAssertTrue(transcript.contains("  re-lock with: semel-swift prepare"), transcript)
            XCTAssertFalse(transcript.contains("over the 1048576-byte limit"), transcript)
            XCTAssertTrue(transcript.contains("(empty)"), "input: holds nothing of the batch\n\(transcript)")
        }
        // The push's own batch: the count says what was sent and that none of it stands, and
        // leads the refusal under the error's mark; no line says the files were pushed.
        let headline = "\(package) is locked, and the batch changes it without a lock it matches"
        XCTAssertTrue(unbatched.contains("\n❌ push: 20002 files and "), unbatched)
        XCTAssertTrue(unbatched.contains(" sent, and none of it committed\n\(headline)"), unbatched)
        XCTAssertFalse(unbatched.contains("Pushed "), unbatched)
        // A batch the user opened: the push is pending, and the commit reports the refusal.
        XCTAssertTrue(batched.contains("\nSent 20002 files and "), batched)
        XCTAssertTrue(batched.contains(", pending the commit\n"), batched)
        XCTAssertTrue(batched.contains("\n❌ \(headline)"), batched)
        XCTAssertFalse(batched.contains("Committed."), batched)
        XCTAssertTrue(batched.contains("\n❌ commit: no batch is open"), "the refused commit closed the batch\n\(batched)")
        try server.stop()
    }

    /// B-164 as the owner met it, with Charts: `prepare` vendors a dependency whose root
    /// holds a `LICENSE` with no extension, and `push **/*.*`, which matches no such name,
    /// pushes the locked copy whole, says so, and lands.
    func test_aGlobPushOfAPreparedTreePushesTheLockedCopyWholeWithItsLicense() throws {
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        let root = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base", isDirectory: true)
        let tree = base.appendingPathComponent("tree", isDirectory: true)
        let shout = try makeRepository(at: root, license: "Apache License, Version 2.0\n")
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "App",
                platforms: [.macOS(.v14)],
                dependencies: [.package(url: "\(shout.absoluteString)", exact: "1.0.0")],
                targets: [.target(name: "App", dependencies: [.product(name: "Shout", package: "Shout")])]
            )

            """, to: tree.appendingPathComponent("Package.swift"))
        try write("import Shout\npublic let loud = shout\n", to: tree.appendingPathComponent("Sources/App/App.swift"))
        try EndToEndRun.run("semel-swift", arguments: ["prepare", tree.path, "--platform", "macos"], timeout: 300,
                            step: "prepare")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("Dependencies/Shout/LICENSE").path),
                      "prepare vendored the dependency with its licence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("Dependencies/Shout.semel-lock").path))

        let server = ServerSession(home: root.appendingPathComponent("home", isDirectory: true))
        try server.start()
        defer { server.killIfRunning() }

        let transcript = try semel(["base \(base.path)", "push **/*.*", "ls tree/Dependencies/Shout"], server: server)
        XCTAssertTrue(transcript.contains("Pushing tree/Dependencies/Shout whole: it is locked\n"), transcript)
        XCTAssertFalse(transcript.contains("is locked, and the batch changes it"), transcript)
        XCTAssertFalse(transcript.contains("❌"), transcript)
        XCTAssertTrue(transcript.contains("LICENSE"), "the licence is in input:\n\(transcript)")
        try server.stop()
    }

    /// Runs `semel` with each argument a command line, as a script does, and returns all it
    /// printed. A refused push is an error, so the exit status is not asserted.
    private func semel(_ commands: [String], server: ServerSession) throws -> String {
        let process = ManagedProcess(executable: EndToEndRun.binary("semel"), arguments: commands,
                                     environment: server.environment)
        try process.start()
        guard process.waitForExit(timeout: 600) != nil else {
            process.kill()
            throw EndToEndFailure(step: commands.joined(separator: "; "), message: "did not exit within 600 s",
                                  commandLine: process.commandLine, outputTail: process.outputTail())
        }
        return process.output
    }

    // MARK: - The fixture

    private func build(_ run: EndToEndRun, _ project: Project, into out: URL, server: ServerSession, step: String) throws {
        try EndToEndRun.run("semel", arguments: ["base \(run.base.path)", "build \(project.buildFolder) --into \(out.path)"],
                            environment: server.environment, timeout: project.buildTimeout, step: step,
                            serverLog: { server.logTail })
    }

    /// A git repository holding one library, `Shout`, tagged 1.0.0, with a `LICENSE` at its
    /// root when one is given.
    private func makeRepository(at root: URL, license: String? = nil) throws -> URL {
        let repository = root.appendingPathComponent("repositories/Shout", isDirectory: true)
        try write("""
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(name: "Shout", products: [.library(name: "Shout", targets: ["Shout"])],
                                  targets: [.target(name: "Shout")])

            """, to: repository.appendingPathComponent("Package.swift"))
        try write("public let shout = \"HELLO\"\n", to: repository.appendingPathComponent("Sources/Shout/Shout.swift"))
        if let license {
            try write(license, to: repository.appendingPathComponent("LICENSE"))
        }
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
