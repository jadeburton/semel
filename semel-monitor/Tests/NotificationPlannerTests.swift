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
        let changes = planner.settle(.errors(records: [Events.compileError(products: entries)], products: nil),
                                     Events.settled(errors: 1))

        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(CardText.headline(of: card), "1 product in error")
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
                                     .errors(records: [second, first], products: nil),
                                     Events.settled(computed: 2, errors: 2),
                                     Events.artifacts(changed: ["output:/c/config.txt"]))

        XCTAssertEqual(changes.count, 1, "the artifacts after an error settle's card make no second card")
        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(card.kind, .errors)
        XCTAssertEqual(CardText.lines(for: card), [
            "2 products in error",
            "c/src/a.c:1:1: error: first",
            "hello, tool",
            "2 errors · 2 products in error",
        ])
    }

    func test_anErrorCardStaysPastEightSecondsUntilClicked() throws {
        let planner = planner()
        let card = try XCTUnwrap(planner.settle(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))], products: nil),
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
            .errors(records: [Events.compileError(products: Events.products("output:/c/hello", "output:/c/hello.dylib"))], products: nil),
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
        let errorCard = try XCTUnwrap(planner.settle(.errors(records: [unneeded], products: nil), Events.settled(errors: 1)).first?.shownCard)
        XCTAssertEqual(CardText.headline(of: errorCard), "1 error")

        XCTAssertEqual(planner.settle(Events.progress(), Events.settled(errors: 0)), [.dismissed(errorCard)])
    }

    func test_errorsWithoutASettledAreShownWhenTheNextSettleBegins() throws {
        let planner = planner()
        XCTAssertEqual(planner.receive(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))], products: nil)), [])
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
        planner.settle(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))], products: nil),
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
                                    .errors(records: [Events.compileError(products: Events.products("output:/Lib/libA.a"))], products: nil),
                                    Events.settled(errors: 1))
        XCTAssertEqual(errors, [], "an error stopping only products outside the folders makes no card")
    }

    func test_folderPrefixesAreSpelledOneWay() {
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "App"), "output:/App/")
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "App/"), "output:/App/")
        XCTAssertEqual(NotificationPlanner.prefix(ofFolder: "output:/App"), "output:/App/")
    }

    // MARK: - The running card (phase 3)

    func test_aSettleRunningNodesIsOneRunningCardUpdatedInPlace() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(pending: 5, running: ["a", "b"])).first?.shownCard)
        XCTAssertEqual(running.kind, .running)
        XCTAssertEqual(CardText.lines(for: running), [
            "Building · 2 running · 5 ahead",
            "ClangCompiler  src/a.c",
            "ClangCompiler  src/b.c",
            "0 computed · 0 from cache · 5 pending",
        ])
        XCTAssertNil(planner.lastCard, "a running card is not a settle's card")

        let changes = planner.receive(Events.progress(computed: 2, pending: 3, running: ["c"]))
        guard case .progressed(let updated)? = changes.first, changes.count == 1 else {
            return XCTFail("expected the running card updated in place, got \(changes)")
        }
        XCTAssertEqual(updated.id, running.id)
        XCTAssertEqual(CardText.lines(for: updated), [
            "Building · 1 running · 3 ahead",
            "ClangCompiler  src/c.c",
            "2 computed · 0 from cache · 3 pending",
        ])
        XCTAssertEqual(planner.cards, [updated])
        XCTAssertEqual(planner.settleInProgress, Events.record(computed: 2, pending: 3, running: ["c"]))
    }

    func test_theRunningCardBecomesTheResultInItsPlace() throws {
        let planner = planner()
        let older   = try XCTUnwrap(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/one"]))
                                        .first?.shownCard)
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        XCTAssertEqual(planner.cards.map(\.id), [running.id, older.id])

        XCTAssertEqual(planner.receive(Events.settled(computed: 3, fromCache: 9)), [], "the card waits for the products")
        let changes = planner.receive(Events.artifacts(changed: ["output:/c/two"]))
        guard case .resolved(let result)? = changes.first, changes.count == 1 else {
            return XCTFail("expected the running card resolved, got \(changes)")
        }
        XCTAssertEqual(result.id, running.id, "in its place, under its id")
        XCTAssertEqual(CardText.lines(for: result), ["1 product changed", "two", "3 computed · 9 from cache"])
        XCTAssertEqual(planner.cards.map(\.id), [running.id, older.id])
        XCTAssertEqual(planner.lastCard, result)
        XCTAssertNil(planner.settleInProgress)

        clock.advance(by: NotificationPlanner.resultLifetime)
        XCTAssertEqual(planner.advance(), [.dismissed(older), .dismissed(result)], "and goes as a result goes")
    }

    func test_theRunningCardBecomesTheErrorCardInItsPlace() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        let changes = planner.settle(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))], products: nil),
                                     Events.settled(errors: 1))
        guard case .resolved(let errors)? = changes.first, changes.count == 1 else {
            return XCTFail("expected the running card resolved, got \(changes)")
        }
        XCTAssertEqual(errors.id, running.id)
        XCTAssertEqual(errors.kind, .errors)
        XCTAssertTrue(planner.holdsErrorCard)
        XCTAssertEqual(planner.receive(Events.artifacts(appeared: ["output:/c/other"])), [],
                       "the settle made its card at settled")
    }

    func test_aSettleThatStartsNothingShowsNoRunningCard() {
        let planner = planner()
        XCTAssertEqual(planner.receive(Events.progress()), [], "a record listing nothing running")
        XCTAssertEqual(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"])).map(Self.kind),
                       ["shown"])
        XCTAssertEqual(planner.cards.map(\.kind), [.result])
    }

    func test_aRunningCardWhoseSettleMovedNothingGoesOnTheClock() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        XCTAssertNil(planner.nextDeadline, "nothing to wait on while the settle runs")
        XCTAssertEqual(planner.receive(Events.settled()), [])
        XCTAssertEqual(planner.nextDeadline, NotificationPlanner.artifactsWait)

        clock.advance(by: NotificationPlanner.artifactsWait)
        XCTAssertEqual(planner.advance(), [.dismissed(running)])
        XCTAssertTrue(planner.cards.isEmpty)
        XCTAssertNil(planner.lastCard)
    }

    func test_theNextSettleRetiresARunningCardStillWaitingForProducts() throws {
        let planner = planner()
        let first = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        planner.receive(Events.settled())
        let changes = planner.receive(Events.progress(running: ["b"]))
        XCTAssertEqual(changes.map(Self.kind), ["dismissed", "shown"])
        XCTAssertEqual(changes.first, .dismissed(first))
        XCTAssertEqual(planner.cards.map(CardText.runningLines(of:)), [["ClangCompiler  src/b.c"]])
    }

    /// B-168. Every running node is a line, named by what it is computed for, and the clock
    /// moves none of them: a card that changed without a `progress` would show one node
    /// where another was, which reads as the second replacing the first.
    func test_theRunningCardListsEveryRunningNodeAndTheClockMovesNone() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a", "b", "c"])).first?.shownCard)
        XCTAssertEqual(CardText.runningLines(of: running), ["ClangCompiler  src/a.c", "ClangCompiler  src/b.c",
                                                            "ClangCompiler  src/c.c"])
        XCTAssertNil(planner.nextDeadline, "nothing waits on the clock while the settle runs")

        clock.advance(by: .seconds(10))
        XCTAssertEqual(planner.advance(), [])
        XCTAssertEqual(planner.cards, [running])
    }

    /// B-168. Across two consecutive records, a node still running keeps its place above
    /// the ones that started after it, a node that finished leaves its line, and a node that
    /// started is a new line at the bottom.
    func test_aNodeThatKeepsRunningKeepsItsLineAndANewOneIsANewLineBelow() throws {
        let planner = planner()
        planner.receive(Events.progress(running: ["a", "b", "c"]))
        let changes = planner.receive(Events.progress(pending: 4, running: ["b", "c", "d"]))
        guard case .progressed(let updated)? = changes.first else {
            return XCTFail("expected the running card updated in place, got \(changes)")
        }
        XCTAssertEqual(CardText.runningLines(of: updated), ["ClangCompiler  src/b.c", "ClangCompiler  src/c.c",
                                                            "ClangCompiler  src/d.c"])
    }

    /// More running nodes than the card lists: the first that started, a line each, and the
    /// rest counted.
    func test_theRunningCardCountsTheNodesBeyondThoseItLists() throws {
        let names   = (0..<(CardText.runningNodesListed + 3)).map { "n\($0)" }
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: names)).first?.shownCard)
        let lines   = CardText.runningLines(of: running)
        XCTAssertEqual(lines.count, CardText.runningNodesListed + 1)
        XCTAssertEqual(lines.first, "ClangCompiler  src/n0.c")
        XCTAssertEqual(lines.last, "and 3 more")
    }

    func test_aRunningCardClickedAwayStaysAwayForTheRestOfItsSettle() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        XCTAssertEqual(planner.dismiss(cardID: running.id), [.dismissed(running)])
        XCTAssertEqual(planner.receive(Events.progress(running: ["b"])), [])
        XCTAssertNotNil(planner.settleInProgress, "the settle still runs")

        let result = try XCTUnwrap(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"]))
                                       .first?.shownCard)
        XCTAssertEqual(result.kind, .result, "its result is a card of its own")
        XCTAssertEqual(planner.receive(Events.progress(running: ["c"])).compactMap(\.shownCard).map(\.kind), [.running],
                       "and the next settle has its running card")
    }

    func test_aPauseShowsNoRunningCard() {
        let planner = planner()
        planner.pause()
        XCTAssertEqual(planner.receive(Events.progress(running: ["a"])), [])
        XCTAssertNotNil(planner.settleInProgress, "a pause silences the card, not the state")
    }

    func test_aDroppedConnectionTakesTheRunningCardWithIt() throws {
        let planner = planner()
        let running = try XCTUnwrap(planner.receive(Events.progress(running: ["a"])).first?.shownCard)
        XCTAssertEqual(planner.engineLost(), [.dismissed(running)])
        XCTAssertNil(planner.settleInProgress)
    }

    // MARK: - --print's running lines

    func test_printWritesTheRunningCardOncePerChangeOfItsNodesAndAtMostOnceASecond() throws {
        let planner = planner()
        let printer = CardPrinter(clock: clock)
        XCTAssertEqual(printer.lines(for: planner.receive(Events.progress(running: ["a"]))),
                       ["running: Building · 1 running · 5 ahead", "  ClangCompiler  src/a.c"])

        clock.advance(by: .milliseconds(500))
        XCTAssertEqual(printer.lines(for: planner.receive(Events.progress(pending: 4, running: ["a", "b", "c"]))), [],
                       "within the second")
        clock.advance(by: .seconds(1))
        XCTAssertEqual(printer.lines(for: planner.receive(Events.progress(pending: 3, running: ["a", "b", "c"]))),
                       ["running: Building · 3 running · 3 ahead", "  ClangCompiler  src/a.c", "  ClangCompiler  src/b.c",
                        "  ClangCompiler  src/c.c"], "a second on, and the set moved since the last line")
        clock.advance(by: .seconds(2))
        XCTAssertEqual(printer.lines(for: planner.receive(Events.progress(pending: 2, running: ["a", "b", "c"]))), [],
                       "the same running set is no line, however long after")
        XCTAssertEqual(printer.lines(for: planner.advance()), [], "nor is the clock")

        clock.advance(by: .seconds(1))
        XCTAssertEqual(printer.lines(for: planner.receive(Events.progress(pending: 0, running: ["c"]))),
                       ["running: Building · 1 running · 0 ahead", "  ClangCompiler  src/c.c"])
        XCTAssertEqual(printer.lines(for: planner.settle(Events.settled(computed: 4), Events.artifacts(changed: ["output:/c/hello"]))),
                       ["card: 1 product changed", "  hello", "  4 computed · 0 from cache"])
    }

    // MARK: - Trees (B-150 item 4)

    func test_aTreeProductThatMovedIsNamedByItsFolderAndCountedOnce() throws {
        let planner = planner()
        let entries = ["output:/App/App.app/Contents/Info.plist", "output:/App/App.app/Contents/MacOS/App"]
        let folders = Dictionary(uniqueKeysWithValues: entries.map { ($0, "output:/App/App.app") })
        let changes = planner.settle(Events.settled(), Events.artifacts(appeared: [entries[1]], changed: [entries[0], "output:/App/lib.a"],
                                                                        treeFolders: folders))
        let card = try XCTUnwrap(changes.first?.shownCard)
        XCTAssertEqual(CardText.headline(of: card), "2 products changed", "a tree with one entry changed is a tree that changed")
        XCTAssertEqual(CardText.namesLine(of: card), "App.app, lib.a")
    }

    func test_aTreesEntriesGivenAValueReplaceTheErrorCardNamingItsFolder() throws {
        let planner = planner()
        let entry = StoppedProduct(path: "output:/App/App.app/Contents/Info.plist", treeFolder: "output:/App/App.app")
        let errors = try XCTUnwrap(planner.settle(.errors(records: [Events.compileError(products: [entry])], products: nil),
                                                  Events.settled(errors: 1)).first?.shownCard)
        let changes = planner.settle(Events.progress(), Events.settled(errors: 1),
                                     Events.artifacts(changed: [entry.path], treeFolders: [entry.path: "output:/App/App.app"]))
        XCTAssertEqual(changes.first, .dismissed(errors))
    }

    // MARK: - The connection

    func test_aDroppedConnectionForgetsTheSettleItWasReading() {
        let planner = planner()
        planner.receive(.errors(records: [Events.compileError(products: Events.products("output:/c/hello"))], products: nil))
        planner.engineLost()
        XCTAssertEqual(planner.settle(Events.settled(), Events.artifacts(changed: ["output:/c/hello"])).compactMap(\.shownCard)
                           .map(\.kind), [.result])
    }

    // MARK: - Helpers

    private static func kind(_ change: CardChange) -> String {
        switch change {
        case .shown:      return "shown"
        case .dismissed:  return "dismissed"
        case .folded:     return "folded"
        case .updated:    return "updated"
        case .progressed: return "progressed"
        case .resolved:   return "resolved"
        }
    }
}
