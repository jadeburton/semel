# A Mac app that shows what the build did: notifications first, the graph later

Status: design; phase 1 built — see "As built (phase 1)" at the end. Follows the 2026-10-11
request for a Mac app that shows notifications when build products appear, change or
disappear, to grow later into a real-time view of the nodes at work. Mockups of the cards,
the status item, the products window and the live window:
`2026-10-11-semel-monitor-mockups.html` beside this file, a page with no dependencies that
opens in any browser.

## The problem

The engine already tells its clients what a settle did. Every subscribed connection
receives `settled` with its four counts, `artifacts` with the products that appeared,
changed and disappeared, `errors` with the typed records, and `progress` with the nodes
running and the queue ahead (B-95). The prompt prints them, the watcher prints them, and a
person whose editor fills the screen sees none of it. With the watcher running (B-126), a
save is a build, and nothing on screen says the product is there.

## Decisions

- **A fifth client, observing.** `semel-monitor` is an executable of the root package
  beside `semel`, `semel-swift`, `semel-clang` and `semel-watch`. It opens the socket as
  the others do, sends `subscribe`, and renders events. It issues no push, no removal, no
  build: it changes nothing in the engine, so it can run all day beside anything else. It
  does not start a server either; with no engine running its menu item says so and it
  waits, reconnecting with the watcher's backoff when the socket appears. The engine stays
  a time-free zone; the app is where time lives, as the watcher's quiet interval is.
- **The engine's own vocabulary, not a new one.** A notification says what the events say:
  *appeared*, *changed*, *disappeared*, the error report's "without a value" and the
  settle's counts. Product paths under `output:` are rendered as the report renders them
  (B-145): the file name, the `output:` path only to break a tie, a tree product by its
  folder. Nothing is parsed out of text; the events are typed and so is the model.
- **One notification per settle, not per product.** A `git checkout` changes fifty
  products in one settle; fifty cards are noise. A settle produces one card: a headline
  (`3 products changed, 1 appeared` or `2 products without a value`), up to three names,
  `and N more`, and the counts line in small type. A settle that changed nothing and
  produced no error shows nothing. Errors use the report's first line for the first
  cause, so a compile error's card reads as the compiler wrote it.
- **The app draws its own cards, in the top-right corner.** Not the system notification
  centre: that requires a bundled, identified app and a permission prompt, groups and
  truncates on its own rules, cannot be updated in place while a settle runs, and could not
  host the graph view the second version wants. The app is an accessory process
  (`NSApplication` with the accessory activation policy, so no Dock icon and no menu bar
  takeover) with a status item in the menu bar and non-activating panels for the cards:
  stacked under the menu bar at the top right of the screen holding the mouse, newest on
  top, dismissed after eight seconds unless the pointer is over them, dismissed at once by
  a click, at most five on screen with older ones folded into the bottom card's `and N
  earlier`. Focus modes are respected by asking `NSWorkspace` whether notifications are
  suppressed, and the menu has *Pause* for the rest.
- **A settle in progress is one card that updates in place.** `progress` events carry the
  running nodes and the queue ahead; while a settle runs, the card shows `Building · 12
  running · 48 ahead` with the names of the running nodes cycling, and becomes the result
  card on `settled`. This is the seed of the second version: the same model, drawn larger.
- **The status item shows the engine's state** with one glyph: no engine, idle, settling
  (with the pending count), errors held. Its menu: the last settle's summary line, *Pause
  notifications*, *Products…*, *Show window* (greyed in the first version), *Quit*.
- **It is a client of the private file system, like the prompt.** Clicking a card, or
  *Products…*, opens a window listing the products under `output:` as `ls` lists them —
  by folder, with the ones this settle touched marked — and every error in the report's
  lines, selectable for copying. From there a person exports: select products or a
  folder, choose a destination in a standard save panel, and the app writes them exactly
  as `export <folder> --into <dir>` does, through the same client code. That is the whole
  of its relation to the disk. The app knows nothing about where another client exported
  — the watcher's `--into`, a `build`'s `semel-out` — and offers no *Reveal in Finder*,
  because such a location may or may not have been updated by whoever exported last, and
  a button that opens a stale file would be a lie. The truth is in `output:`; the app
  shows that and lets the person take a copy when they want one.
- **Testable without a screen.** `SemelMonitor` is a library with a pure model:
  `NotificationPlanner` takes events in and yields cards out — the headline, the names,
  the counts, the in-place update of a running card, the folding, the pause — and a
  `Clock` the tests drive. The executable is the AppKit shell: a status item, panels that
  draw a card, the socket. `semel-monitor --print` runs the same model with no panels and
  writes each card as lines on standard output, which is what the end-to-end test reads
  and what a script can tail.
- **Built like the other executables.** A SwiftPM target, linked against `SemelCLI` for the
  socket and the renderers and against `SemelProtocol` for the events, built by
  `scripts/build.sh` and by CI; AppKit is imported in the executable only. No Xcode project,
  no bundle, no signing in the first version; the day it needs a bundle (an icon, system
  notifications, a login item) it becomes an Xcode project Semel builds itself, which
  would be a fitting roster entry.

## The shape

```
semel-monitor [--print] [--only <folder>]... [--no-pause-on-focus]

semel-monitor/
  Sources/SemelMonitor/
    NotificationPlanner      events in, cards out; the running card; folding; pause
    Card                     headline, names, counts, kind (result, running, errors)
    Clock                    what the planner waits on; a test's is driven by hand
  main.swift                 arguments; the socket and resubscription; --print
  App/
    StatusItem               the menu bar glyph and menu
    CardPanel                one non-activating panel drawing one card
    CardStack                placement under the menu bar, newest on top, at most five
  Tests/                     the planner, the card text, folding, pause, the clock
```

`--only <folder>` keeps cards for products under those folders of `output:`, for a person
with two projects in one engine; the default is every product.

## What one save does, with the watcher running

1. The watcher pushes `View.swift` and commits. The engine's `progress` events arrive at
   the monitor: the status item turns to settling, and a running card appears top right:
   `Building · 3 running · 12 ahead`, naming `SwiftCompiler App/View.swift`.
2. `settled` arrives, then `artifacts` with `changed: [output:/App/App]`. The running card
   becomes `1 product changed`, with `App` under it and `3 computed · 9 from cache` in
   small type, and goes after eight seconds.
3. If `errors` arrived instead, the card is red-marked, its headline is the first cause's
   line one, `App without a value` under it, and it stays until clicked, since an error is
   something to act on.

## The second version: the graph, live

The `progress` record already carries every running node with its type and name, the
queue ahead and the running totals. The window behind *Show window* draws them: a list of
running nodes with elapsed time, a bar for pending against scheduled, the settle's counts,
and the last settle's products and errors. That needs no protocol change. A view of the
graph itself — nodes, wires, which are pending, which hold values — needs requests that do
not exist yet: a typed walk of the graph's shape (`debug` prints it as text today) and a
subscription to node state changes. Those are the second design, and the second version
will state what it needs when the first has shown what people look at.

## Phases

Decided 2026-10-11: delivered in clear phases, each a working app on its own.

1. **Notifies, nothing more.** The executable, the socket with resubscription and the
   watcher's backoff, the status item with two states (no engine, connected) and a menu
   of *Pause notifications* and *Quit*, the planner, result cards that go after eight
   seconds and error cards that stay until dismissed, `--only`, `--print`, and the tests
   for all of that. No products window, no export, no running card, no node names: a
   settle in progress shows nothing until it ends. Clicking a card dismisses it.
2. **The products window and export.** *Products…* and the click on a card open the
   window listing `output:`, marking the settle's products, showing the errors' lines,
   and exporting a selection through the prompt's export code.
3. **The running card and the live window.** The running card updated from `progress`,
   then *Show window* with the running nodes, the queue and the counts, over the same
   events. The full graph view is designed separately when this phase has shown what
   people look at.

## Testing

- `NotificationPlannerTests`: one card per settle; nothing for an empty settle; the
  headline's forms; three names and `and N more`; a tree product named by its folder; an
  error settle's card from the first cause; a running card updated in place by `progress`
  and replaced by the result; folding beyond five; pause swallowing cards and resuming;
  `--only` filtering; the clock driving dismissal.
- `CardTextTests`: the lines `--print` writes, pinned.
- `ProductsExportTests` (root package, in-process server): the products window's listing
  equals `ls output:` by folder; exporting a selection into a temporary folder writes the
  same bytes and modes `export <folder> --into <dir>` writes, through the same code.
- `SemelEndToEndTests`: `semel-monitor --print` against a real `semelserv` over the C
  fixture: a push, a settle, the card's lines on standard output; the engine stopped and
  restarted, the monitor reconnecting and reporting the next settle.
- Not tested: the panels' pixels. The AppKit shell is kept thin enough to read.

## Open for review

- The name: `semel-monitor` is proposed; `semel-notify` says less, `semel-view` says more
  than the first version does.

## Decided on review (2026-10-11)

- An error card stays until dismissed: a click, or the next settle that leaves the
  product with a value, which replaces it. A result card goes after eight seconds. An
  error is something to act on; a product that changed is something to know.
- No *Reveal in Finder*, and no knowledge of external locations at all. The app is a
  client of the private file system: it lists `output:` and exports to a destination the
  person chooses, through the prompt's own export code, and that is its only relation to
  the disk. Above, under "a client of the private file system".

## As built (phase 1)

Built as phase 1 states; where the code and the design differed, or the design left a
choice, this is what was done.

- **A settle is read as the prompt reads it.** The engine sends one settle as `errors`
  (only when it found new failures), `settled` (only when it scheduled anything) and
  `artifacts` (only when a product moved), in that order — the order
  `CommandInterpreter` prints them in. Nothing marks a settle's end, so the planner does
  not wait for all three: an error settle's card is made at `settled` and the `artifacts`
  after it only replaces older error cards; a result card is made at `artifacts`, with the
  counts of the `settled` before it; the next settle's first event — a `progress`, an
  `errors` after a `settled` — closes whatever is held. A removal that scheduled nothing
  and still collected a product is a card with no counts line. No timer pairs events.
- **The error card follows the mockup.** Its headline is `2 products without a value`
  (or `1 error` for errors no product needs); the first cause's line one, as the report
  draws it — the first block under the report's first heading — is the line under it,
  then the names, then the report's own summary line, `1 error · 2 products without a
  value`. The renderers are the report's: `ErrorReportRenderer` and `ProductNames` in
  `SemelCLI` gained a small public surface (`firstLine(of:)`, `summaryLine(for:)`,
  `errorCount(of:)`, `productsWithoutValue`, `ProductNames.name(of:)`) and nothing new
  draws a name.
- **Which error cards a later settle replaces.** An error card waits on its products,
  keyed as the report keys them (a tree by its folder); an `artifacts` that gives every
  one of them a value replaces it, and a `settled` whose error count is zero replaces
  every error card, since the graph then holds no error. A card for errors no product
  needs is replaced only by the latter.
- **A tree product in a result card is not named by its folder.** The `artifacts` event
  carries entry paths and no tree folder, and taking paths apart to guess one would read
  text the event does not type. Error cards name a tree by its folder, from
  `StoppedProduct.treeFolder`. Filed as B-150 item 4.
- **The order of a result card's names** is changed, then appeared, then disappeared, each
  in the event's path order — the headline's order, which leads with changed because a save
  changes what was there.
- **Folding.** The sixth card folds the oldest off the bottom; the new bottom card's
  `earlier` is the folded card's plus one. A card that goes takes its count with it.
- **Hover** holds a result card; leaving it gives the card its full eight seconds again.
- **Pause** swallows new cards and nothing else: cards on screen still expire and error
  cards are still replaced. *Resume* shows the last card made during the pause, unless it
  was an error card a later settle replaced.
- **`--print`** writes `card: <headline>` and the card's other lines indented two spaces,
  `dismissed: <headline>` when one goes (expired, clicked or replaced), `folded:
  <headline>` when one is folded, and `status: connected` / `status: no engine` when the
  connection comes or goes, so a script can tell a quiet engine from a missing one.
- **The subscription is in the library**, not in `main.swift`: `EngineSubscription` opens
  the socket, says `hello` and `subscribe`, and reopens with the watcher's backoff (a
  quarter of a second doubling to five). The socket tells only its waiters when it closes,
  so an open connection is asked whether it still is four times a second. `Monitor` ties
  the planner, the subscription and the one timer for the next expiry together on the main
  queue; the panels and `--print` are its two front ends.
- **The status item's menu** is the state line (`No engine`, `Connected · last settle: 3
  changed, 1 appeared`), *Pause notifications* or *Resume*, and *Quit semel-monitor*.
  *Products…* and *Show window* arrive with their phases.
- **Focus is not read.** `NSWorkspace` has no public way to ask whether a Focus mode is
  on, and `INFocusStatusCenter` answers only a bundled app the person has authorised, so
  `--no-pause-on-focus` does not exist and *Pause notifications* is the switch.
- **The Xcode workspace is unchanged.** `semel-monitor/` is a folder of the root package,
  which the workspace already holds as `group:.`, as it holds `semel-watch/`; the lint
  configuration's `included:` list names it.
