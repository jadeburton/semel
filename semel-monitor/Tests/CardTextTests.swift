//
//  CardTextTests.swift
//  SemelMonitorTests
//
//  B-150. The words on a card and the lines `--print` writes, pinned: what the end-to-end
//  test and a script read.
//

import SemelProtocol
import XCTest
@testable import SemelMonitor

final class CardTextTests: XCTestCase {

    private func result(changed: [String] = [], appeared: [String] = [], disappeared: [String] = [],
                        counts: SettleCounts? = SettleCounts(computed: 3, fromCache: 9),
                        treeFolders: [String: String] = [:]) -> Card {
        Card(id: 1, content: .result(changed: changed, appeared: appeared, disappeared: disappeared, counts: counts,
                                     treeFolders: treeFolders))
    }

    // MARK: - Headlines

    func test_theHeadlineCountsEachKindAndNamesProductsOnce() {
        XCTAssertEqual(CardText.headline(of: result(changed: ["output:/a"])), "1 product changed")
        XCTAssertEqual(CardText.headline(of: result(changed: ["output:/a", "output:/b", "output:/c"], appeared: ["output:/d"])),
                       "3 products changed, 1 appeared")
        XCTAssertEqual(CardText.headline(of: result(appeared: ["output:/a"], disappeared: ["output:/b", "output:/c"])),
                       "1 product appeared, 2 disappeared")
    }

    func test_anErrorHeadlineCountsTheProductsWithoutAValue() {
        let records = [Events.compileError(products: Events.products("output:/a", "output:/b"))]
        XCTAssertEqual(CardText.headline(of: Card(id: 1, content: .errors(records: records))), "2 products in error")
    }

    func test_theStatusSummaryIsTheHeadlineWithoutItsNoun() {
        XCTAssertEqual(CardText.summary(of: result(changed: ["output:/a", "output:/b", "output:/c"], appeared: ["output:/d"])),
                       "3 changed, 1 appeared")
    }

    // MARK: - Names

    func test_threeNamesAndThenHowManyMore() {
        let card = result(changed: ["output:/c/a", "output:/c/b"], appeared: ["output:/c/c", "output:/c/d", "output:/c/e"])
        XCTAssertEqual(CardText.namesLine(of: card), "a, b, c and 2 more")
        XCTAssertEqual(CardText.namesLine(of: result(changed: ["output:/c/a", "output:/c/b", "output:/c/c"])), "a, b, c")
    }

    // MARK: - --print

    func test_printWritesAResultCardAsTheMockupShowsIt() {
        let card = result(changed: ["output:/App/App", "output:/Packages/libModels.a", "output:/Packages/libConversations.a"],
                          appeared: ["output:/Packages/libNotifications.a"])
        XCTAssertEqual(CardText.printed(.shown(card)), [
            "card: 3 products changed, 1 appeared",
            "  App, libModels.a, libConversations.a and 1 more",
            "  3 computed · 9 from cache",
        ])
        XCTAssertEqual(CardText.printed(.dismissed(card)), ["dismissed: 3 products changed, 1 appeared"])
        XCTAssertEqual(CardText.printed(.folded(card)), ["folded: 3 products changed, 1 appeared"])
        XCTAssertEqual(CardText.printed(.updated(card)), [])
    }

    func test_printWritesAnErrorCardAsTheMockupShowsIt() {
        let line = "input:/Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type "
                 + "'String' to specified type 'Int'"
        let records = [Events.compileError(line, products: Events.products("output:/Packages/libConversations.a",
                                                                           "output:/Packages/libExplore.a"))]
        XCTAssertEqual(CardText.printed(.shown(Card(id: 2, content: .errors(records: records)))), [
            "card: 2 products in error",
            "  Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' to specified type 'Int'",
            "  libConversations.a, libExplore.a",
            "  1 error · 2 products in error",
        ])
    }

    /// B-168. A running node a line, named by its type and what it is computed for as the
    /// error report names a subject: a compile by its module, a compiler by its source, a
    /// linker by its product; a node with no subject by its path, and one with neither by
    /// its type alone.
    func test_printWritesARunningCardAsItsHeadlineAndItsNodesAndItsResultAsACard() {
        let record  = ProgressRecord(scheduled: 88, computed: 31, fromCache: 9, pending: 48,
                                     running: [ActiveNode(type: "SwiftCompiler", name: "", subject: .target(name: "Models"),
                                                          identity: "3fa2c1d07e"),
                                               ActiveNode(type: "ClangCompiler", name: "input:/Sources/App/main.m.p",
                                                          subject: .source(path: "input:/Sources/App/main.m"),
                                                          identity: "9b04e7aa11"),
                                               ActiveNode(type: "ClangLinker", name: "", subject: .product(path: "output:/c/hello"),
                                                          identity: "51cc0e2f9d"),
                                               ActiveNode(type: "StaticFile", name: "input:/c/src/hello.c"),
                                               ActiveNode(type: "ProjectBuilder", name: "")])
        let running = Card(id: 3, content: .running(record: record))
        XCTAssertEqual(CardText.lines(for: running), [
            "Building · 5 running · 48 ahead",
            "SwiftCompiler  Models",
            "ClangCompiler  Sources/App/main.m",
            "ClangLinker  hello",
            "StaticFile  c/src/hello.c",
            "ProjectBuilder",
            "31 computed · 9 from cache · 48 pending",
        ])
        XCTAssertNil(CardText.namesLine(of: running), "a running card names nodes, not products")
        XCTAssertEqual(CardText.barFraction(of: running), 40.0 / 88.0)
        let printed = ["running: Building · 5 running · 48 ahead", "  SwiftCompiler  Models", "  ClangCompiler  Sources/App/main.m",
                       "  ClangLinker  hello", "  StaticFile  c/src/hello.c", "  ProjectBuilder"]
        XCTAssertEqual(CardText.printed(.shown(running)), printed)
        XCTAssertEqual(CardText.printed(.progressed(running)), printed)
        XCTAssertEqual(CardText.printed(.dismissed(running)), ["dismissed: Building · 5 running · 48 ahead"])

        let result = result(changed: ["output:/c/hello"])
        XCTAssertEqual(CardText.printed(.resolved(result)), ["card: 1 product changed", "  hello", "  3 computed · 9 from cache"])
    }

    /// B-168. Two running nodes of one type and one subject — one module compiled under two
    /// configurations — are told apart by the start of their identities; a third of another
    /// subject needs nothing more.
    func test_twoRunningNodesOfOneTypeAndSubjectAreToldApartByTheirIdentities() {
        let nodes = [ActiveNode(type: "SwiftCompiler", name: "", subject: .target(name: "Models"), identity: "3fa2c1d07e55"),
                     ActiveNode(type: "SwiftCompiler", name: "", subject: .target(name: "Models"), identity: "9b04e7aa1100"),
                     ActiveNode(type: "SwiftCompiler", name: "", subject: .target(name: "App"), identity: "51cc0e2f9d00"),
                     ActiveNode(type: "SwiftLinker", name: "", subject: .target(name: "Models"), identity: "77aa0e2f9d00")]
        XCTAssertEqual(RunningNodeNames.lines(of: nodes), [
            "SwiftCompiler  Models #3fa2c1d0",
            "SwiftCompiler  Models #9b04e7aa",
            "SwiftCompiler  App",
            "SwiftLinker  Models",
        ])
    }

    func test_aTreesEntriesAreNamedOnceByItsFolder() {
        let entries = ["output:/App/App.app/Contents/Info.plist", "output:/App/App.app/Contents/MacOS/App"]
        let card = result(appeared: entries, treeFolders: Dictionary(uniqueKeysWithValues: entries.map { ($0, "output:/App/App.app") }))
        XCTAssertEqual(CardText.lines(for: card), ["1 product appeared", "App.app", "3 computed · 9 from cache"])
    }

    func test_aCardWithoutCountsHasNoCountsLineAndTheBottomCardSaysWhatItFolded() {
        var card = result(disappeared: ["output:/Packages/libOld.a"], counts: nil)
        card.earlier = 2
        XCTAssertEqual(CardText.lines(for: card), ["1 product disappeared", "libOld.a", "and 2 earlier"])
    }
}
