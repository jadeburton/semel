//
//  AutostartTests.swift
//  SemelEndToEndTests
//
//  B-110. A `semel` that finds no server starts one and leaves it running; `semel stop`
//  ends it. Through the real executables, with a home of their own.
//

import Foundation
import SemelTestSupport
import XCTest

final class AutostartTests: XCTestCase {

    private var home: URL!

    private var socketPath: String { home.appendingPathComponent("semelserv.sock").path }
    private var environment: [String: String] { ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        // Short, as the harness's roots are: a Unix socket path has 103 bytes, and the
        // process temporary directory plus a UUID is already past that.
        home = URL(fileURLWithPath: "/tmp/semel-autostart/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A daemon a failed assertion left behind stops the way `stop` stops it.
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    private func semel(_ arguments: String..., step: String) throws -> String {
        try EndToEndRun.run("semel", arguments: arguments, environment: environment, timeout: 60, step: step).output
    }

    func test_semelStartsTheServerItFindsMissingAndLeavesItRunning() throws {
        let first = try semel("ls", step: "first semel, no server")
        XCTAssertTrue(first.contains("Started semelserv (log: \(home.path)/semelserv.log)"), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the daemon is left listening")

        let second = try semel("ls", step: "second semel")
        XCTAssertFalse(second.contains("Started semelserv"), "the second client finds the first's daemon: \(second)")
    }

    /// B-109, B-119. The loop the missing-settings report describes, end to end: a build
    /// with no machine file fails naming `semel-clang`; that tool, run outside Semel on the
    /// folder the formula looks in, writes the three clang namespaces the formula selects
    /// and no other tool's; and the next build follows the file in and succeeds, with no
    /// key in the file left unused.
    func test_theMissingSettingsLoopIsBuildWriteBuild() throws {
        let tree = home.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true),
                                         to: tree.appendingPathComponent("c", isDirectory: true))
        let machineFile = tree.appendingPathComponent(EndToEndRun.machineFileName).path
        let out = home.appendingPathComponent("out").path

        // Nothing to follow yet: the file the formula names is not on disk, so the report
        // names it as unpushed and every tool below it says what it lacks and what writes it.
        let failed = try semelExpectingFailure("base \(tree.path)", "build c --into \(out)", step: "build without the machine file")
        XCTAssertTrue(failed.contains("semel.machine.config has not been pushed\n   · run semel-clang . to write it"), failed)
        XCTAssertTrue(failed.contains("Run 'semel-clang <folder>'"), failed)

        let wrote = try EndToEndRun.run("semel-clang", arguments: [tree.path], timeout: 60, step: "semel-clang").output
        XCTAssertTrue(wrote.contains("Wrote \(machineFile): clang.compiler, clang.linker, clang.preprocessor\n"
                                     + "Those c/hello.fmla selects;"), wrote)
        XCTAssertFalse(try String(contentsOfFile: machineFile, encoding: .utf8).contains("swift."), wrote)

        let built = try semel("base \(tree.path)", "build c --into \(out)", step: "build with the machine file")
        XCTAssertTrue(built.contains("Push file: semel.machine.config"), built)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "\(out)/hello"), built)
        XCTAssertFalse(built.contains("unused configuration key"), built)
    }

    /// A run whose non-zero exit is the point: the output comes back either way, and the
    /// status is asserted rather than thrown on.
    private func semelExpectingFailure(_ arguments: String..., step: String) throws -> String {
        let process = ManagedProcess(executable: EndToEndRun.binary("semel"), arguments: arguments, environment: environment)
        try process.start()
        guard let status = process.waitForExit(timeout: 60) else {
            process.kill()
            _ = process.waitForExit(timeout: 5)
            throw EndToEndFailure(step: step, message: "timed out", commandLine: process.commandLine, outputTail: process.outputTail())
        }
        XCTAssertNotEqual(status, 0, "\(step): expected a failing build, got:\n\(process.output)")
        return process.output
    }

    func test_stopEndsTheServerAndASecondStopFindsNothing() throws {
        _ = try semel("ls", step: "start")

        let stop = try semel("stop", step: "stop")
        XCTAssertTrue(stop.contains("Stopping semelserv at \(socketPath)"), stop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        let again = try semel("stop", step: "stop again")
        XCTAssertTrue(again.contains("No server running at \(socketPath)"), again)
    }
}
