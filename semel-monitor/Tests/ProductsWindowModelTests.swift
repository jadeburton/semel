//
//  ProductsWindowModelTests.swift
//  SemelMonitorTests
//
//  B-150 phase 2. The products window as a value: its folders and the errors on the left,
//  the rows of the folder shown with the settle's marks and their sizes, where it opens,
//  what a selection exports and copies, a refresh that keeps the selection, and the lines
//  `--print` writes for it.
//

import SemelCLI
import SemelProtocol
import XCTest
@testable import SemelMonitor

final class ProductsWindowModelTests: XCTestCase {

    // MARK: - A snapshot

    private static func file(_ path: String, size: Int? = 100, status: EntryStatus = .unreferenced) -> ListEntry {
        ListEntry(path: path, kind: .file, size: size, mode: 0o644, status: status)
    }

    private static func folder(_ path: String) -> ListEntry {
        ListEntry(path: path, kind: .folder, size: nil, mode: nil, status: .none)
    }

    private static let snapshot = ProductsSnapshot(folders: [
        FolderListing(folder: "", entries: [folder("App"), folder("Packages")]),
        FolderListing(folder: "App", entries: [file("App/App", size: 2_400_000)]),
        FolderListing(folder: "Packages", entries: [
            file("Packages/libConversations.a", size: nil, status: .failed),
            file("Packages/libModels.a", size: 1_200_000),
            file("Packages/libNotifications.a", size: 212_000),
        ]),
    ], errors: [])

    private static func resultCard(changed: [String] = [], appeared: [String] = []) -> Card {
        Card(id: 1, content: .result(changed: changed, appeared: appeared, disappeared: [],
                                     counts: SettleCounts(computed: 1, fromCache: 0)))
    }

    // MARK: - What it lists

    func test_theLeftColumnIsEveryFolderAndTheErrors() {
        let model = ProductsWindowModel(snapshot: Self.snapshot, card: nil)
        XCTAssertEqual(model.sections, [.folder(""), .folder("App"), .folder("Packages"), .errors])
        XCTAssertEqual(model.sections.map(model.title(of:)), ["output:", "App", "Packages", "Errors (0)"])
    }

    func test_aFoldersRowsCarryTheSettlesMarksAndTheirSizes() {
        var model = ProductsWindowModel(snapshot: Self.snapshot,
                                        card: Self.resultCard(changed: ["output:/Packages/libModels.a"],
                                                              appeared: ["output:/Packages/libNotifications.a"]))
        XCTAssertEqual(model.section, .folder("Packages"), "opened on the folder of the first product the card names")
        XCTAssertEqual(model.rows.map(\.name), ["libConversations.a", "libModels.a", "libNotifications.a"])
        XCTAssertEqual(model.rows.map(\.mark), [.noValue, .changed, .appeared])
        XCTAssertEqual(model.rows.map(\.sizeText), ["—", "1.2 MB", "212 KB"])

        model.select(.folder(""))
        XCTAssertEqual(model.rows.map(\.name), ["App/", "Packages/"], "a folder is listed as `ls` lists it")
        XCTAssertEqual(model.rows.map(\.mark), [nil, nil])
    }

    func test_anErrorCardOpensOnTheErrorsInTheReportsLines() {
        let record = Events.compileError(products: Events.products("output:/Packages/libConversations.a"))
        let snapshot = ProductsSnapshot(folders: Self.snapshot.folders, errors: [record])
        let model = ProductsWindowModel(snapshot: snapshot, card: Card(id: 2, content: .errors(records: [record])))

        XCTAssertEqual(model.section, .errors)
        XCTAssertEqual(model.title(of: .errors), "Errors (1)")
        XCTAssertEqual(model.errorLines, ErrorReportRenderer.lines(for: [record], style: ErrorReportStyle()))
        XCTAssertEqual(model.errorLines.last, "1 error · 1 product without a value")
        XCTAssertNil(model.exportRequest, "nothing to export from the errors")
        XCTAssertEqual(model.copiedPaths, ["output:/Packages/libConversations.a"])
    }

    func test_productsOpensOnTheFirstFolderHoldingAProductWithNoCard() {
        let model = ProductsWindowModel(snapshot: Self.snapshot, card: nil)
        XCTAssertEqual(model.section, .folder("App"))
        XCTAssertEqual(model.rows.map(\.mark), [nil])
    }

    // MARK: - Selection, export and copy

    func test_withNothingSelectedTheWholeFolderIsExportedAndCopied() {
        let model = ProductsWindowModel(snapshot: Self.snapshot, card: Self.resultCard(changed: ["output:/Packages/libModels.a"]))
        XCTAssertEqual(model.exportTitle, "Export Packages…")
        XCTAssertEqual(model.exportRequest, ExportRequest(folder: "Packages", selection: nil, suggestedName: "Packages"))
        XCTAssertEqual(model.copiedPaths, ["output:/Packages"])
    }

    func test_aSelectionIsWhatIsExportedAndCopied() {
        var model = ProductsWindowModel(snapshot: Self.snapshot, card: Self.resultCard(changed: ["output:/Packages/libModels.a"]))
        model.selectRows(["Packages/libNotifications.a", "Packages/libModels.a", "Elsewhere/notShown.a"])

        XCTAssertEqual(model.selectedRows, ["Packages/libModels.a", "Packages/libNotifications.a"], "only rows shown")
        XCTAssertEqual(model.exportTitle, "Export 2 products…")
        XCTAssertEqual(model.exportRequest?.selection, ["Packages/libModels.a", "Packages/libNotifications.a"])
        XCTAssertEqual(model.copiedPaths, ["output:/Packages/libModels.a", "output:/Packages/libNotifications.a"],
                       "in the order the rows are listed")

        model.select(.folder(""))
        XCTAssertEqual(model.selectedRows, [], "another section starts with nothing selected")
        model.selectRows(["Packages"])
        XCTAssertEqual(model.exportTitle, "Export 1 folder…")
        XCTAssertEqual(model.exportRequest, ExportRequest(folder: "", selection: ["Packages"], suggestedName: "output"))
    }

    func test_aRefreshKeepsWhatIsStillThereSelectedAndTakesTheNewMarks() {
        var model = ProductsWindowModel(snapshot: Self.snapshot, card: Self.resultCard(changed: ["output:/Packages/libModels.a"]))
        model.selectRows(["Packages/libModels.a", "Packages/libNotifications.a"])
        let fewer = ProductsSnapshot(folders: [
            FolderListing(folder: "", entries: [Self.folder("Packages")]),
            FolderListing(folder: "Packages", entries: [Self.file("Packages/libModels.a")]),
        ], errors: [])

        model.refresh(with: fewer, card: Self.resultCard(appeared: ["output:/Packages/libModels.a"]))

        XCTAssertEqual(model.section, .folder("Packages"))
        XCTAssertEqual(model.selectedRows, ["Packages/libModels.a"])
        XCTAssertEqual(model.rows.map(\.mark), [.appeared])

        model.refresh(with: ProductsSnapshot(folders: [FolderListing(folder: "", entries: [])], errors: []), card: nil)
        XCTAssertEqual(model.section, .folder(""), "a folder that went leaves the root shown")
        XCTAssertEqual(model.exportRequest, nil, "an empty folder has nothing to export")
    }

    // MARK: - Sizes and --print

    func test_sizesAreDecimalAndTheSameInEveryLocale() {
        XCTAssertEqual(ByteSize.text(1), "1 byte")
        XCTAssertEqual(ByteSize.text(23), "23 bytes")
        XCTAssertEqual(ByteSize.text(33_456), "33 KB")
        XCTAssertEqual(ByteSize.text(1_249_000), "1.2 MB")
        XCTAssertEqual(ByteSize.text(3_050_000_000), "3.1 GB")
    }

    func test_theLinesPrintWritesForAWindow() {
        let card  = Self.resultCard(changed: ["output:/Packages/libModels.a"])
        let model = ProductsWindowModel(snapshot: Self.snapshot, card: card)
        XCTAssertEqual(ProductsWindowText.lines(for: model, openedFor: card), [
            "window: 1 product changed",
            "  output: · App · [Packages] · Errors (0)",
            "  libConversations.a · no value · —",
            "  libModels.a · changed · 1.2 MB",
            "  libNotifications.a · 212 KB",
        ])
        XCTAssertEqual(ProductsWindowText.lines(failing: "No engine", openedFor: nil), ["window: products", "  No engine"])
    }
}
