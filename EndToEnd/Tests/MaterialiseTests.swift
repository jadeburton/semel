//
//  MaterialiseTests.swift
//  SemelEndToEndTests
//
//  The two steps before any build, on their own: they are fast, and a failure here is
//  about the tree or the machine, not about Semel.
//

import XCTest

final class MaterialiseTests: XCTestCase {

    private var run: EndToEndRun?

    override func tearDown() {
        run?.cleanUp()
        run = nil
        super.tearDown()
    }

    func test_aFixtureRunCopiesTheWholeTreeUnderAShortRoot() throws {
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run

        try run.materialise()

        XCTAssertTrue(run.root.path.hasPrefix("/tmp/semel-tests/"), run.root.path)
        XCTAssertLessThan(run.root.appendingPathComponent("home3/semelserv.sock").path.utf8.count, 104)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("c/hello.fmla").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.base.appendingPathComponent("swift/HelloApp/semel.fmla").path))
    }

    /// B-109. The machine file beside the C fixtures says what this machine has — the
    /// clang the descriptor names and the SDK where the linker reads it — for the clang
    /// namespaces and no other.
    func test_configureWritesTheMachineFileTheCFixturesRead() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.cHello)
        self.run = run
        try run.materialise()

        try run.configure()

        let written = try String(contentsOf: run.base.appendingPathComponent("semel.machine.config"), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("// Written by semel-clang for --platform macos"), written)
        XCTAssertTrue(written.contains("clang.linker.toolDescriptor.version=" + (try MachineFacts.clangVersion())), written)
        XCTAssertTrue(written.contains("clang.linker.sdkPath=" + (try MachineFacts.macOSSDKPath())), written)
        XCTAssertFalse(written.contains("swift."), "the clang namespaces only: \(written)")
    }

    // MARK: - Overlays

    /// A checkout and an overlay in a temporary folder, each written from a map of relative
    /// path to contents; removed at the end of the test.
    private func checkoutAndOverlay(checkout checkoutFiles: [String: String],
                                    overlay overlayFiles: [String: String]) throws -> (checkout: URL, overlay: URL) {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-overlay-\(UUID().uuidString.prefix(8))", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let checkout = folder.appendingPathComponent("checkout", isDirectory: true)
        let overlay  = folder.appendingPathComponent("overlay", isDirectory: true)
        for (root, files) in [(checkout, checkoutFiles), (overlay, overlayFiles)] {
            for relativePath in files.keys.sorted() {
                let file = root.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((files[relativePath] ?? "").utf8).write(to: file)
            }
        }
        return (checkout, overlay)
    }

    private func contents(of folder: URL, _ relativePath: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(relativePath))).map { String(decoding: $0, as: UTF8.self) }
    }

    /// B-77: a correction deep in a sample's tree replaces that file and nothing else — the
    /// overlay's `App` merges into the checkout's rather than replacing it — and the
    /// overlay's note stays out of the checkout, whose own `README.md` a project may list.
    func test_anOverlayReplacesANestedFileAndLeavesTheRestOfItsFolder() throws {
        let (checkout, overlay) = try checkoutAndOverlay(
            checkout: ["App/Orders/OrderDetailView.swift": "sample", "App/Orders/OrderRow.swift": "row",
                       "App/App.swift": "app", "README.md": "the sample's"],
            overlay:  ["App/Orders/OrderDetailView.swift": "corrected", "README.md": "the overlay's"])

        try EndToEndRun.lay(overlay: overlay, over: checkout, replacingOnly: true)

        XCTAssertEqual(contents(of: checkout, "App/Orders/OrderDetailView.swift"), "corrected")
        XCTAssertEqual(contents(of: checkout, "App/Orders/OrderRow.swift"), "row")
        XCTAssertEqual(contents(of: checkout, "App/App.swift"), "app")
        XCTAssertEqual(contents(of: checkout, "README.md"), "the sample's")
    }

    /// A correction whose path the checkout does not have would add a file nothing
    /// compiles and leave the uncorrected one in the build, so it fails where it happens.
    func test_anOverlayOfCorrectionsRefusesAFileTheCheckoutDoesNotHave() throws {
        let (checkout, overlay) = try checkoutAndOverlay(
            checkout: ["App/Orders/OrderDetailView.swift": "sample"],
            overlay:  ["App/Order/OrderDetailView.swift": "corrected"])

        XCTAssertThrowsError(try EndToEndRun.lay(overlay: overlay, over: checkout, replacingOnly: true))
        XCTAssertEqual(contents(of: checkout, "App/Orders/OrderDetailView.swift"), "sample")
    }

    /// NetNewsWire's shape (B-77): a source the project generates before its build is not in
    /// the checkout, but its template is beside where it goes, and that pins the path as a
    /// file the checkout has does. Without the template it is refused like any other.
    func test_anOverlayOfCorrectionsAddsTheOutputOfATemplateTheCheckoutHas() throws {
        let (checkout, overlay) = try checkoutAndOverlay(
            checkout: ["Modules/Secrets/Sources/Secrets/SecretKey.swift.gyb": "template"],
            overlay:  ["Modules/Secrets/Sources/Secrets/SecretKey.swift": "generated"])

        try EndToEndRun.lay(overlay: overlay, over: checkout, replacingOnly: true)

        XCTAssertEqual(contents(of: checkout, "Modules/Secrets/Sources/Secrets/SecretKey.swift"), "generated")
        XCTAssertEqual(contents(of: checkout, "Modules/Secrets/Sources/Secrets/SecretKey.swift.gyb"), "template")

        let (elsewhere, misplaced) = try checkoutAndOverlay(
            checkout: ["Modules/Secrets/Sources/Secrets/SecretKey.swift.gyb": "template"],
            overlay:  ["Modules/Secrets/Sources/SecretKey.swift": "generated"])
        XCTAssertThrowsError(try EndToEndRun.lay(overlay: misplaced, over: elsewhere, replacingOnly: true))
    }

    /// The Lua shape (B-76): a formula the checkout lacks is added, and a project config it
    /// happens to have is replaced.
    func test_aFormulaOverlayAddsItsFormulaAndReplacesAConfig() throws {
        let (checkout, overlay) = try checkoutAndOverlay(
            checkout: ["lua.c": "source", "semel.config": "the checkout's"],
            overlay:  ["lua.fmla": "formula", "semel.config": "the roster's"])

        try EndToEndRun.lay(overlay: overlay, over: checkout, replacingOnly: false)

        XCTAssertEqual(contents(of: checkout, "lua.fmla"), "formula")
        XCTAssertEqual(contents(of: checkout, "semel.config"), "the roster's")
        XCTAssertEqual(contents(of: checkout, "lua.c"), "source")
    }

    func test_configurePreparesAProjectWithAPlatform() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let run = try EndToEndRun(project: Projects.swiftMyApp)
        self.run = run
        try run.materialise()

        try run.configure()

        let config = try String(contentsOf: run.base.appendingPathComponent("swift/MyApp/semel.config"), encoding: .utf8)
        XCTAssertTrue(config.contains("swift.compiler.target=arm64-apple-macosx13.0"), config)
        XCTAssertFalse(config.contains("clang.linker"), "a package tree never links through clang")
    }
}
