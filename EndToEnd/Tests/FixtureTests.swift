//
//  FixtureTests.swift
//  SemelEndToEndTests
//
//  Every fixture, through the whole run, on every `swift test`. One test per project so
//  a failure names the project in the test's name, not only in its message.
//

import XCTest

final class FixtureTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
    }

    private func build(_ project: Project, file: StaticString = #filePath, line: UInt = #line) throws {
        let run = try EndToEndRun(project: project)
        do {
            try run.run()
        } catch {
            XCTFail("\(project.name)\n\(error)", file: file, line: line)
        }
    }

    func test_cHello() throws          { try build(Projects.cHello) }
    func test_tutorial() throws        { try build(Projects.tutorial) }
    func test_cppEmu6502() throws      { try build(Projects.cppEmu6502) }
    func test_swiftMyApp() throws      { try build(Projects.swiftMyApp) }
    func test_swiftCPackage() throws   { try build(Projects.swiftCPackage) }
    func test_swiftHelloApp() throws   { try build(Projects.swiftHelloApp) }

    /// The roster and the tests above must not drift apart.
    func test_everyFixtureInTheRosterHasATestHere() {
        let tested: Set<String> = ["c-hello", "tutorial", "cpp-emu6502", "swift-my-app", "swift-c-package", "swift-hello-app"]
        XCTAssertEqual(Set(Projects.fixtures.map(\.name)), tested)
    }
}
