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
}
