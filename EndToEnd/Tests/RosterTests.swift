//
//  RosterTests.swift
//  SemelEndToEndTests
//

import XCTest

final class RosterTests: XCTestCase {

    func test_namesAreDistinct() {
        XCTAssertEqual(Set(Projects.all.map(\.name)).count, Projects.all.count)
    }

    func test_everyFixtureFolderAndItsFormulaAreInTheRepository() {
        for project in Projects.fixtures {
            let folder = EndToEndEnvironment.fixtures.appendingPathComponent(project.buildFolder, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "\(project.name): no \(folder.path)")
            let formulas = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".fmla") } ?? []
            XCTAssertEqual(formulas.count, 1, "\(project.name): expected one formula in \(folder.path), found \(formulas)")
        }
    }

    func test_noFixtureCommitsAConfig() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: EndToEndEnvironment.fixtures.path))
        let configs = enumerator.compactMap { $0 as? String }.filter {
            $0.hasSuffix("semel.config") || $0 == "clang.cfg"
        }
        XCTAssertEqual(configs, [], "machine values must not be committed")
    }

    func test_theCTemplateHasBothPlaceholdersAndNothingElseUnrendered() throws {
        let template = try String(contentsOf: EndToEndEnvironment.fixtures.appendingPathComponent("clang.cfg.template"), encoding: .utf8)

        XCTAssertTrue(template.contains("${CLANG_VERSION}"))
        XCTAssertTrue(template.contains("${MACOS_SDK_PATH}"))
        let placeholders = template.components(separatedBy: "${").dropFirst().map { $0.prefix { $0 != "}" } }
        XCTAssertEqual(Set(placeholders.map(String.init)), ["CLANG_VERSION", "MACOS_SDK_PATH"])
    }

    /// `docs/tutorial/first-node.md` copies `EndToEnd/Fixtures/c` to build its `hello/src`,
    /// and quotes line counts against it; `Fixtures/tutorial/src` is that same copy, kept
    /// as its own fixture rather than a reference to `Fixtures/c/src`. The two trees have
    /// to match byte for byte or the tutorial's prose goes false silently.
    func test_theTutorialFixtureSourcesMatchTheCFixture() throws {
        let cSrc = EndToEndEnvironment.fixtures.appendingPathComponent("c/src", isDirectory: true)
        let tutorialSrc = EndToEndEnvironment.fixtures.appendingPathComponent("tutorial/src", isDirectory: true)
        let fileManager = FileManager.default
        let reason = "docs/tutorial/first-node.md copies Fixtures/c and quotes line counts against it; " +
                     "Fixtures/tutorial/src must be the same sources"

        let cNames = Set(try fileManager.subpathsOfDirectory(atPath: cSrc.path))
        let tutorialNames = Set(try fileManager.subpathsOfDirectory(atPath: tutorialSrc.path))
        XCTAssertEqual(cNames, tutorialNames, reason)

        for name in cNames.intersection(tutorialNames) {
            let cData = try Data(contentsOf: cSrc.appendingPathComponent(name))
            let tutorialData = try Data(contentsOf: tutorialSrc.appendingPathComponent(name))
            XCTAssertEqual(cData, tutorialData, "\(name): \(reason)")
        }
    }

    /// `docs/tutorial/first-node.md` Part 4 and its spec quote `hello.c: 14`, `hello2.c:
    /// 12`, `main.c: 16` — `LineCounter.lineCount(of:)`'s output on these sources. This
    /// target cannot import `SemelExamples`, so the count is reimplemented here rather
    /// than shared; `SemelExamplesTests` pins the same algorithm on the node itself.
    func test_theLineCountsTheTutorialQuotesAreTheFixturesLineCounts() throws {
        func lineCount(of text: String) -> Int {
            guard !text.isEmpty else { return 0 }
            let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            return text.hasSuffix("\n") ? newlines : newlines + 1
        }

        let src = EndToEndEnvironment.fixtures.appendingPathComponent("tutorial/src", isDirectory: true)
        let expected = ["hello.c": 14, "hello2.c": 12, "main.c": 16]
        let reason = "the tutorial and the spec quote these counts"

        for (name, count) in expected {
            let text = try String(contentsOf: src.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(lineCount(of: text), count, "\(name): \(reason)")
        }
    }
}
