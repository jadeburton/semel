//
//  ProductsPresenterTests.swift
//  SemelMonitorTests
//
//  B-150 phase 2. The window's life over a source a test fills: opened, read off the main
//  queue and announced once; read again after a settle while open and not once closed;
//  and an engine that is not there said as the status item says it.
//

import SemelCLI
import SemelProtocol
import SemelTransport
import XCTest
@testable import SemelMonitor

final class ProductsPresenterTests: XCTestCase {

    private final class ScriptedSource: ProductsSource {
        var snapshots: [ProductsSnapshot]
        var failure: Error?
        private(set) var reads = 0

        init(snapshots: [ProductsSnapshot]) {
            self.snapshots = snapshots
        }

        func snapshot() throws -> ProductsSnapshot {
            reads += 1
            if let failure {
                throw failure
            }
            return snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]
        }

        func export(_ request: ExportRequest, into destination: String) throws -> ExportResult {
            ExportResult(written: 0, messages: [])
        }
    }

    private static func snapshot(_ paths: String...) -> ProductsSnapshot {
        ProductsSnapshot(folders: [FolderListing(folder: "", entries: paths.map {
            ListEntry(path: $0, kind: .file, size: 1, mode: 0o644, status: .unreferenced)
        })], errors: [])
    }

    private var displays: [(display: ProductsPresenter.Display, isOpening: Bool)] = []

    private func presenter(over source: ScriptedSource) -> ProductsPresenter {
        let presenter = ProductsPresenter(source: source)
        presenter.onDisplay = { [weak self] in self?.displays.append(($0, $1)) }
        return presenter
    }

    /// Runs the main queue until `count` displays have come.
    private func waitForDisplays(_ count: Int) {
        let deadline = Date().addingTimeInterval(5)
        while displays.count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func test_anOpenWindowIsReadAnnouncedOnceAndReadAgainAfterASettle() throws {
        let source = ScriptedSource(snapshots: [Self.snapshot("hello"), Self.snapshot("hello", "hello.dylib")])
        let presenter = presenter(over: source)
        let card = Card(id: 1, content: .result(changed: ["output:/hello"], appeared: [], disappeared: [], counts: nil))

        presenter.open(for: card, marks: card)
        waitForDisplays(2)
        XCTAssertEqual(displays.map(\.isOpening), [false, true])
        XCTAssertEqual(displays.first?.display, .loading)
        guard case .shown(let opened) = displays.last?.display else {
            return XCTFail("not shown: \(displays)")
        }
        XCTAssertEqual(opened.rows.map(\.mark), [.changed])

        presenter.settleEnded(marks: nil)
        waitForDisplays(3)
        guard case .shown(let refreshed) = displays.last?.display else {
            return XCTFail("not shown: \(displays)")
        }
        XCTAssertEqual(displays.last?.isOpening, false)
        XCTAssertEqual(refreshed.rows.map(\.name), ["hello", "hello.dylib"])
        XCTAssertEqual(refreshed.rows.map(\.mark), [nil, nil], "the marks are the newest settle's")

        presenter.close()
        presenter.settleEnded(marks: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(source.reads, 2, "a closed window reads nothing")
    }

    func test_noEngineIsSaidAsTheStatusItemSaysIt() {
        let source = ScriptedSource(snapshots: [Self.snapshot()])
        source.failure = ConnectionError.unavailable(path: "/tmp/semelserv.sock", underlying: "no such file")
        let presenter = presenter(over: source)

        presenter.open(for: nil, marks: nil)
        waitForDisplays(2)

        XCTAssertEqual(displays.last?.display, .failed("No engine"))
        XCTAssertEqual(displays.last?.isOpening, true)
    }
}
