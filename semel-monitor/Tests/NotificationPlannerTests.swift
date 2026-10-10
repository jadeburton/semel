//
//  NotificationPlannerTests.swift
//  SemelMonitorTests
//
//  B-150. Events in, cards out: one card per settle and none for a settle that moved
//  nothing; error cards from the first cause, standing until clicked or replaced; at most
//  five on screen; pause and resume; `--only`; and the clock, moved by hand, deciding when
//  a result card goes.
//

import SemelProtocol
import XCTest
@testable import SemelMonitor

final class NotificationPlannerTests: XCTestCase {

    private let clock = ManualClock()

    private func planner(only: [String] = []) -> NotificationPlanner {
        NotificationPlanner(clock: clock, only: only)
    }

    // MARK: - One card per settle

    func test_aSettleThatMovedProductsMakesOneCard() throws {
        let planner = planner()
        let changes = planner.settle(Events.progress(),
                                     Events.settled(computed: 3, fromCache: 9),
                                     Events.artifacts(appeared: ["output:/c/hello"],
                                                      changed: ["output:/c/a.o", "output:/c/b.o", "output:/c/c.o"]))

        XCTAssertEqual(changes.count, 1)
        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(CardText.lines(for: card), [
            "3 products changed, 1 appeared",
            "a.o, b.o, c.o and 1 more",
            "3 computed · 9 from cache",
        ])
        XCTAssertEqual(planner.cards.map(\.id), [card.id])
    }

    func test_aSettleThatMovedNothingMakesNoCard() {
        let planner = planner()
        XCTAssertEqual(planner.settle(Events.progress(), Events.settled(computed: 4)), [])
        // The next settle's progress closes it, still with nothing to show.
        XCTAssertEqual(planner.settle(Events.progress()), [])
        XCTAssertTrue(planner.cards.isEmpty)
        XCTAssertNil(planner.lastCard)
    }

    func test_aRemovalThatScheduledNothingStillShowsWhatDisappeared() throws {
        let planner = planner()
        let card = try XCTUnwrap(planner.settle(Events.artifacts(disappeared: ["output:/c/old.a"])).first?.shownCard)
        XCTAssertEqual(CardText.lines(for: card), ["1 product disappeared", "old.a"])
    }

    func test_eachSettleMakesItsOwnCardAndTheNewestIsOnTop() {
        let planner = planner()
        planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/one"]))
        planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/two"]))

        XCTAssertEqual(planner.cards.map(CardText.namesLine(of:)), ["two", "one"])
    }

    // MARK: - Names

    func test_aTreeProductWithoutAValueIsNamedByItsFolder() throws {
        let planner = planner()
        let entries = [StoppedProduct(path: "output:/App/App.app/Contents/MacOS/App", treeFolder: "output:/App/App.app"),
                       StoppedProduct(path: "output:/App/App.app/Contents/Info.plist", treeFolder: "output:/App/App.app")]
        let changes = planner.settle(.errors(records: [Events.compileError(products: entries)]),
                                     Events.settled(errors: 1))

        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(CardText.headline(of: card), "1 product without a value")
        XCTAssertEqual(CardText.namesLine(of: card), "App.app")
    }

    func test_twoProductsOfOneNameAreToldApartByTheirPathUnderOutput() throws {
        let planner = planner()
        let changes = planner.settle(Events.settled(), Events.artifacts(changed: ["output:/a/lib.a", "output:/b/lib.a"]))
        XCTAssertEqual(try XCTUnwrap(changes.first?.shownCard).products.count, 2)
        XCTAssertEqual(planner.cards.first.flatMap(CardText.namesLine(of:)), "a/lib.a, b/lib.a")
    }

    // MARK: - Errors

    func test_anErrorSettleMakesOneErrorCardFromTheFirstCause() throws {
        let planner = planner()
        let first  = Events.compileError("input:/c/src/a.c:1:1: error: first", products: Events.products("output:/c/hello"))
        let second = Events.compileError("input:/c/src/b.c:2:2: error: second", products: Events.products("output:/c/tool"))
        let changes = planner.settle(Events.progress(),
                                     .errors(records: [second, first]),
                                     Events.settled(computed: 2, errors: 2),
                                     Events.artifacts(changed: ["output:/c/config.txt"]))

        XCTAssertEqual(changes.count, 1, "the artifacts after an error settle's card make no second card")
        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(card.kind, .errors)
        XCTAssertEqual(CardText.lines(for: card), [
            "2 products without a value",
            "c/src/a.c:1:1: error: first",
            "hello, tool",
            "2 errors · 2 products without a value",
        ])
    }

    func test_anErrorCardStaysPastEightSecondsUntilClicked() throws {
        let planner = planner()
        let card = try XCTUnwrap(planner.settle(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))]),
                                                Events.settled(errors: 1)).first?.shownCard)
        clock.advance(by: .seconds(60))
        XCTAssertEqual(planner.advance(), [])
        XCTAssertNil(planner.nextDeadline)
        XCTAssertEqual(planner.dismiss(cardID: card.id), [.dismissed(card)])
        XCTAssertTrue(planner.cards.isEmpty)
    }

    func test_aLaterSettleGivingTheProductsAValueReplacesTheErrorCard() throws {
        let planner = planner()
        let errorCard = try XCTUnwrap(planner.settle(
            .errors(records: [Events.compileError(products: Events.products("output:/c/hello", "output:/c/hello.dylib"))]),
            Events.settled(errors: 1)).first?.shownCard)

        // One of the two has a value; the graph still holds the error.
        let partly = planner.settle(Events.progress(), Events.settled(errors: 1),
                                    Events.artifacts(changed: ["output:/c/hello"]))
        XCTAssertFalse(partly.contains(.dismissed(errorCard)))

        let fixed = planner.settle(Events.progress(), Events.settled(errors: 1),
                                   Events.artifacts(changed: ["output:/c/hello.dylib"]))
        XCTAssertEqual(fixed.first, .dismissed(errorCard))
        XCTAssertEqual(planner.cards.map(\.kind), [.result, .result])
    }

    func test_aSettleThatLeavesNoErrorReplacesEveryErrorCard() throws {
        let planner = planner()
        let unneeded = Events.compileError(products: [])
        let errorCard = try XCTUnwrap(planner.settle(.errors(records: [unneeded]), Events.settled(errors: 1)).first?.shownCard)
        XCTAssertEqual(CardText.headline(of: errorCard), "1 error")

        XCTAssertEqual(planner.settle(Events.progress(), Events.settled(errors: 0)), [.dismissed(errorCard)])
    }

    func test_errorsWithoutASettledAreShownWhenTheNextSettleBegins() throws {
        let planner = planner()
        XCTAssertEqual(planner.receive(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))])), [])
        let card = try XCTUnwrap(planner.receive(Events.progress()).first?.shownCard)
        XCTAssertEqual(card.kind, .errors)
    }

    // MARK: - The clock

    func test_aResultCardGoesAfterEightSecondsOnTheClock() throws {
        let planner = planner()
        let card = try XCTUnwrap(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"])).first?.shownCard)
        XCTAssertEqual(planner.nextDeadline, .seconds(8))

        clock.advance(by: .seconds(7))
        XCTAssertEqual(planner.advance(), [])
        clock.advance(by: .seconds(1))
        XCTAssertEqual(planner.advance(), [.dismissed(card)])
        XCTAssertNil(planner.nextDeadline)
    }

    func test_thePointerOverACardHoldsItAndLeavingGivesItItsTimeAgain() throws {
        let planner = planner()
        let card = try XCTUnwrap(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"])).first?.shownCard)
        planner.pointerEntered(cardID: card.id)
        clock.advance(by: .seconds(30))
        XCTAssertEqual(planner.advance(), [])
        XCTAssertNil(planner.nextDeadline)

        XCTAssertEqual(planner.pointerLeft(cardID: card.id), [])
        XCTAssertEqual(planner.nextDeadline, .seconds(38))
        clock.advance(by: .seconds(8))
        XCTAssertEqual(planner.advance(), [.dismissed(card)])
    }

    // MARK: - Folding

    func test_aSixthCardFoldsTheOldestIntoTheBottomCard() {
        let planner = planner()
        for index in 1...5 {
            planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/p\(index)"]))
        }
        let changes = planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/p6"]))

        XCTAssertEqual(planner.cards.count, NotificationPlanner.mostCardsShown)
        XCTAssertEqual(planner.cards.map(CardText.namesLine(of:)), ["p6", "p5", "p4", "p3", "p2"])
        XCTAssertEqual(planner.cards.last?.earlier, 1)
        XCTAssertEqual(planner.cards.last.map(CardText.lines(for:))?.last, "and 1 earlier")
        XCTAssertEqual(changes.map(Self.kind), ["shown", "folded", "updated"])

        planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/p7"]))
        XCTAssertEqual(planner.cards.last?.earlier, 2, "the folded card's count travels with the fold")
    }

    // MARK: - Pause

    func test_pauseSwallowsCardsAndResumeShowsTheLastSettles() throws {
        let planner = planner()
        planner.pause()
        XCTAssertEqual(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/one"])), [])
        XCTAssertEqual(planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/c/two"])), [])
        XCTAssertTrue(planner.cards.isEmpty)

        let shown = try XCTUnwrap(planner.resume().first?.shownCard)
        XCTAssertEqual(CardText.namesLine(of: shown), "two")
        XCTAssertEqual(planner.resume(), [], "a card is shown by one resume only")
    }

    func test_anErrorFixedDuringAPauseIsNotShownOnResume() {
        let planner = planner()
        planner.pause()
        planner.settle(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))]),
                       Events.settled(errors: 1))
        planner.settle(Events.progress(), Events.settled(errors: 0))
        XCTAssertEqual(planner.resume(), [])
    }

    // MARK: - --only

    func test_onlyKeepsProductsUnderItsFolders() throws {
        let planner = planner(only: ["App", "output:/Tools/"])
        let changes = planner.settle(Events.settled(),
                                     Events.artifacts(changed: ["output:/App/App", "output:/Lib/libA.a",
                                                                "output:/Tools/gen", "output:/Application/x"]))
        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(CardText.lines(for: card).prefix(2), ["2 products changed", "App, gen"])

        XCTAssertEqual(planner.settle(Events.progress(), Events.settled(), Events.artifacts(changed: ["output:/Lib/libA.a"])), [])
        let errors = planner.settle(Events.progress(),
                                    .errors(records: [Events.compileError(products: Events.products("output:/Lib/libA.a"))]),
                                    Events.settled(errors: 1))
        XCTAssertEqual(errors, [], "an error stopping only products outside the folders makes no card")
    }

    func test_folderPrefixesAreSpelledOneWay() {
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "App"), "output:/App/")
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "App/"), "output:/App/")
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "output:/App"), "output:/App/")
    }

    // MARK: - The connection

    func test_aDroppedConnectionForgetsTheSettleItWasReading() {
        let planner = planner()
        planner.receive(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))]))
        planner.engineLost()
        XCTAssertEqual(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"])).compactMap(\.shownCard)
                           .map(\.kind), [.result])
    }

    // MARK: - Helpers

    private static func kind(_ change: CardChange) -> String {
        switch change {
        case .shown:     return "shown"
        case .dismissed: return "dismissed"
        case .folded:    return "folded"
        case .updated:   return "updated"
        }
    }
}
