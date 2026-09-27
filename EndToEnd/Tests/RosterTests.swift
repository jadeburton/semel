//
//  RosterTests.swift
//  SemelEndToEndTests
//

import XCTest

final class RosterTests: XCTestCase {

    func test_namesAreDistinct() {
        XCTAssertEqual(Set(Projects.all.map(\.name)).count, Projects.all.count)
    }

    /// `materialise` nests a `.git(subfolder: ".")` checkout, and the repository's own,
    /// under its name, so `buildFolder` has to spell that name back (`Project.Source`'s
    /// doc comments).
    func test_aCheckoutRootedProjectBuildsTheFolderNamedAfterIt() {
        for project in Projects.all {
            let nestsUnderItsName: Bool
            switch project.source {
            case .git(_, _, let subfolder, _): nestsUnderItsName = subfolder == "."
            case .repository:                  nestsUnderItsName = true
            case .fixture:                     nestsUnderItsName = false
            }
            guard nestsUnderItsName else {
                continue
            }
            XCTAssertEqual(project.buildFolder, project.name,
                           "\(project.name): materialise nests the checkout under its name")
        }
    }

    /// The repository's copy leaves the fixtures and every build folder behind, and
    /// carries the formula and the project config the self-build reads (B-78).
    func test_theRepositoryCopyIsTheBuildAndNothingElse() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-roster-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        try EndToEndRun.copyRepository(to: destination)

        for present in ["Package.swift", "semel.fmla", "semel.config", "SemelCore/Package.swift", "EndToEnd/Tests"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(present).path),
                          "\(present) belongs in the copy")
        }
        for absent in [".build", ".git", "EndToEnd/Fixtures", "SemelCore/.build", "semel.machine.config"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(absent).path),
                           "\(absent) does not belong in the copy")
        }

        // Every file the rules keep is there — walked here by a recursion of its own,
        // because the copy's enumerator once dropped the rest of a folder after an
        // excluded file in it.
        let expected = Set(Self.keptFiles(under: EndToEndEnvironment.repositoryRoot, relativeTo: ""))
        let copied   = Set(try FileManager.default.subpathsOfDirectory(atPath: destination.path)
            .filter { !$0.hasSuffix("/.DS_Store") && $0 != ".DS_Store" })
        XCTAssertEqual(expected.subtracting(copied).sorted().prefix(10).joined(separator: ", "), "",
                       "files the copy is missing")
        XCTAssertEqual(copied.subtracting(expected).sorted().prefix(10).joined(separator: ", "), "",
                       "files the copy should have left out")
    }

    /// The relative paths of every file and folder under `folder` that the copy's rules
    /// keep, by the same names and paths `EndToEndRun` excludes.
    private static func keptFiles(under folder: URL, relativeTo prefix: String) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var kept: [String] = []
        for name in entries.sorted() {
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            guard !EndToEndRun.repositoryCopyExcludedNames.contains(name),
                  !EndToEndRun.repositoryCopyExcludedPaths.contains(relative) else {
                continue
            }
            kept.append(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                kept.append(contentsOf: keptFiles(under: folder.appendingPathComponent(name), relativeTo: relative))
            }
        }
        return kept
    }

    /// The fixtures are the cheap tier and are what proves the hermeticity checks: each
    /// one builds again at a second mount and again under a perturbed environment. Only
    /// an external project, where a build costs minutes, turns either off.
    func test_everyFixtureRunsBothHermeticityBuilds() {
        for project in Projects.fixtures {
            XCTAssertTrue(project.twoMounts, "\(project.name): a fixture builds at a second mount")
            XCTAssertTrue(project.perturbed, "\(project.name): a fixture builds under a perturbed environment")
        }
    }

    func test_everyFixtureFolderAndItsFormulaAreInTheRepository() {
        for project in Projects.fixtures {
            let folder = EndToEndEnvironment.fixtures.appendingPathComponent(project.buildFolder, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "\(project.name): no \(folder.path)")
            let formulas = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".fmla") } ?? []
            XCTAssertEqual(formulas.count, 1, "\(project.name): expected one formula in \(folder.path), found \(formulas)")
        }
    }

    /// An overlay for a project with no platform is the two files a C project has no
    /// converter to write (B-76): one formula, which reads the machine file where
    /// `configure` writes it, and the project config that formula lays over it — in the
    /// repository, under `Fixtures`, and nothing more, so the build is the checkout's
    /// sources and the roster's two files.
    func test_everyFormulaOverlayIsOneFormulaAndAProjectConfigInTheRepository() throws {
        for project in Projects.all where project.platform == nil {
            guard let overlay = project.source.overlay else {
                continue
            }
            let folder = EndToEndEnvironment.fixtures.appendingPathComponent(overlay, isDirectory: true)
            let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }.sorted()
            let formulas = entries.filter { $0.hasSuffix(".fmla") }
            XCTAssertEqual(formulas.count, 1, "\(project.name): expected one formula in \(folder.path), found \(entries)")
            XCTAssertEqual(entries, (formulas + ["semel.config"]).sorted(), "\(project.name): an overlay is a formula and a project config")

            for formula in formulas {
                let text = try String(contentsOf: folder.appendingPathComponent(formula), encoding: .utf8)
                XCTAssertTrue(text.contains("<../\(EndToEndRun.machineFileName)>"),
                              "\(project.name): configure writes the machine file beside the checkout, so the formula reads it there")
            }
        }
    }

    /// An overlay for a project with a platform corrects the checkout's own files, and
    /// `prepare` writes the formula and both configs after it is laid. A formula or a
    /// project config in the overlay would be one `prepare` keeps, as it keeps Semel's own,
    /// and the build would be the roster's and not the converter's; a machine file is never
    /// committed. So it holds none of them, and at least one file besides its note. That
    /// each file replaces one the checkout has is `lay`'s to check when the run
    /// materialises, since the checkout is not here.
    func test_everySourceOverlayHoldsFilesAndNoFormulaOrConfig() throws {
        let generated: Set<String> = ["semel.config", EndToEndRun.machineFileName]
        for project in Projects.all where project.platform != nil {
            guard let overlay = project.source.overlay else {
                continue
            }
            let folder = EndToEndEnvironment.fixtures.appendingPathComponent(overlay, isDirectory: true)
            let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path).filter { subpath in
                var isFolder: ObjCBool = false
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(subpath).path, isDirectory: &isFolder)
                return !isFolder.boolValue && !subpath.hasSuffix(".DS_Store") && subpath != EndToEndRun.overlayNoteName
            }
            XCTAssertFalse(files.isEmpty, "\(project.name): \(folder.path) lays nothing")
            for file in files {
                let name = URL(fileURLWithPath: file).lastPathComponent
                XCTAssertFalse(name.hasSuffix(".fmla"), "\(project.name): prepare writes the formula, not the overlay: \(file)")
                XCTAssertFalse(generated.contains(name), "\(project.name): prepare writes the configs, not the overlay: \(file)")
            }
        }
    }

    /// The machine's half of a configuration is written in the harness's copy and holds
    /// one machine's facts; the project's half is committed, being the project's (B-109).
    /// The walk covers every overlay too, being under `Fixtures`.
    func test_noFixtureCommitsAMachineFile() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: EndToEndEnvironment.fixtures.path))
        let files = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(EndToEndRun.machineFileName) }
        XCTAssertEqual(files, [], "machine values must not be committed")
    }

    /// Every C fixture's formula names its project file, and a formula that names a file
    /// the repository does not hold builds only where somebody typed it.
    func test_everyCFixtureCommitsItsProjectConfig() {
        for folder in ["c", "tutorial", "cpp"] {
            let config = EndToEndEnvironment.fixtures.appendingPathComponent("\(folder)/semel.config")
            XCTAssertTrue(FileManager.default.fileExists(atPath: config.path), "\(folder): no semel.config")
        }
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
