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
                        counts: SettleCounts? = SettleCounts(computed: 3, fromCache: 9)) -> Card {
        Card(id: 1, content: .result(changed: changed, appeared: appeared, disappeared: disappeared, counts: counts))
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
        XCTAssertEqual(CardText.headline(of: Card(id: 1, content: .errors(records: records))), "2 products without a value")
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
            "card: 2 products without a value",
            "  Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' to specified type 'Int'",
            "  libConversations.a, libExplore.a",
            "  1 error · 2 products without a value",
        ])
    }

    func test_aCardWithoutCountsHasNoCountsLineAndTheBottomCardSaysWhatItFolded() {
        var card = result(disappeared: ["output:/Packages/libOld.a"], counts: nil)
        card.earlier = 2
        XCTAssertEqual(CardText.lines(for: card), ["1 product disappeared", "libOld.a", "and 2 earlier"])
    }
}
