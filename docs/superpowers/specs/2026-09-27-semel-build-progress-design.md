# Build progress: one line that moves while the client waits (B-95)

Status: design, for review before any code. Companion to the 2026-09-27 node identity
design, whose "As built" section shows the shape this document will end with.

## The problem

The end of a build is told. The settle summary prints when the graph settles, and the
artifact diff under it names what appeared, changed and disappeared. Everything before that
is silent. After `push` the prompt returns at once; `wait`, `build` and `commit` block with
nothing on the screen until the summary. Measured today on the IceCubes packages tree, a
cold `build` is 97 seconds of silence, and a person at a terminal has no way to tell a
compiler at work from a server that has hung.

The transport is there. A subscribed connection already receives the `errors`, `notice`,
`settled` and `artifacts` events, delivered on the connection's reader thread while the
command thread is parked in `wait`. What is missing is an event that says how far a settle
has got, and a renderer that draws it in place instead of scrolling it.

## Decisions

- **The engine reports progress; the client decides whether to show it.** A new
  `DaemonEvent.progress` carries where the current settle stands. The server sends it to
  every subscriber, as it sends `settled`. Whether anything is drawn is the client's
  business, decided from its own terminal, so a script, a test and the harness see exactly
  the output they see today.
- **The event carries the settle's running totals, never a batch's.** `SettleTally` counts
  each node once across batches: a node woken, found waiting on an input, unscheduled and
  woken again is one node. The event reads the same tally the summary is taken from, so the
  numbers it shows are the numbers the summary ends with, and a sum of batches — which
  would count that node twice — never appears.
- **The event carries what both sizes need.** The totals, the number of nodes scheduled and
  not yet started, and the nodes running now, each as its type and a name. The minimal
  renderer reads the counts; a dashboard reads the list. One event, so the second size is a
  renderer and nothing on the wire.
- **Drawn only while this client is blocked.** The indicator appears when a command of this
  client waits for a settle — `wait`, `build`, and the `commit` that ends a batch — and is
  erased before that command prints its result. It is not drawn at an idle prompt. The
  reasoning is in the next section; it is the answer to "how does the user keep typing
  while it redraws": they are not typing, because the command has their thread.
- **On by default at a terminal, off everywhere else.** Shown when standard output is a
  terminal and `TERM` is not `dumb`; never when output is a pipe or a file.
  `SEMEL_PROGRESS=0` turns it off at a terminal, for the person who wants a transcript
  without it, beside `SEMEL_JOBS` as the second environment setting the client reads. Not
  a per-command flag:
  the people who see it are people at a terminal, and an option nobody knows about is an
  option nobody uses.
- **One line first.** The first implementation draws one line. The dashboard — the active
  nodes listed, one per job — is a renderer over the same event and is left for after the
  line has been lived with, because clearing and redrawing N lines is where terminal
  rendering goes wrong and one line is where it does not.

## Why not a status line above the prompt

`ninja` and `cargo` draw their line while the process runs and nobody types; there is no
prompt beneath it. Semel's interactive session has one, and today it is `readLine()` on
standard input with no prompt string and no line editor. Events already print into it from
the reader thread — a settle summary arriving mid-keystroke lands after what was typed so
far, which the terminal's own line discipline tolerates because nothing is ever erased.

A line that redraws in place while the user types cannot share the screen with that. The
redraw erases to the start of the line, taking the half-typed command with it, or it
stays above the input and the client has to own the input line to put it back: a
line editor of its own, raw terminal mode, cursor save and restore, a width to track. That
is a project — the one `linenoise` is — and B-95 is not it.

Drawing only while the client is blocked needs none of that. The command thread is parked
in `request(.wait)`; nothing this client prints comes from anywhere but the event thread,
which is also where the indicator is drawn. The two cases B-95 names — `wait` blocking with
no indication, and `build` running for a minute and a half — are exactly the blocked ones.
A bare `push` at an idle prompt shows nothing new: the settle summary arrives as it does
today, and a person who wants to watch types `wait`.

A mode entered with a verb and left with a key — `watch`, then Escape — was the other
option in B-95. It is the blocked case again, spelled as a command that blocks until a key
is pressed rather than until a settle, and it can be added over this design as one more
verb that waits; it is not needed to answer the two cases above.

## The event

```
DaemonEvent.progress(ProgressRecord)

ProgressRecord
    scheduled: Int          nodes this settle has fetched as scheduled, once each
    computed:  Int          of those, the ones whose latest result was one they ran
    fromCache: Int          of those, the ones whose latest result was a cache entry
    pending:   Int          scheduled and not started: the queue ahead
    running:   [ActiveNode] started and not finished, in start order

ActiveNode
    type: String            the node type's name, `ClangCompiler`
    name: String            what `debug` names the node by: its `name` when it has one,
                            else the last segment of its `input` port's first wire
```

`scheduled`, `computed` and `fromCache` are the `SettleTally`'s three sets, counted.
`pending` is the count of rows scheduled in the database less those in `running`: what
the next rounds of `selectScheduled` will fetch, which rises while the cascade is still
generating work and falls as it drains. `running` is the pass's own set, named.

The event is sent from `processAllNodes`, on the loop's own task, at the two points the
pass changes state: after a round of scheduling starts nodes, and after a result is
written. Not on a `woken` event, which changes nothing the record shows until the next
round schedules. Not from a pass that started nothing: the loop passes through on every
signal that turns out to have no work behind it, and a settle that scheduled nothing says
nothing, as the summary already does not. The last event of a settle has `running` empty
and `pending` zero, and `settled` follows it with the same three totals plus the error
count the idle-time report adds.

No throttle on the server. A cold build of IceCubes computes a few hundred nodes; the
events are one per start and one per finish, a few thousand small frames over a local
socket in a minute and a half. The client throttles the drawing, below, which is where the
cost is.

`ProtocolVersion.current` goes from 15 to 16: a new event case is a new protocol, and an
older `semel` would drop a frame it cannot decode rather than fail, which is the silent
kind of wrong the version check exists to prevent.

## Drawing

```
⏳ 10 running, 340 pending · 1,204 done: 1,100 computed, 104 from cache · 1m 32s
```

Running and pending first, because they are what moves. Done is the tally's
`computed + fromCache`, with the split under it, so the line reads as the summary will:
when it is replaced by `✅ 1,614 nodes scheduled, 1,510 computed, 104 from cache, 0 errors`
the numbers are recognisable. The clock is the client's, from the moment the wait began,
and there is no estimate of what remains: the cascade generates work as it goes, so the
denominator is not known, and a bar that reaches 90% and then grows is worse than a count.

The line is written with a carriage return and an erase-to-end-of-line, no newline, to
standard output, flushed. It is redrawn at most every 100 ms on an event, and once a second
on a timer when no event arrives, so the clock moves under a long compile. When the wait
ends the line is erased, and the command prints what it prints today — `Settled.`, the
build's summary — into a clean line. The transcript left on the screen is the transcript a
terminal shows today, which is what `docs/tutorial/first-node.md` quotes.

Anything else the client prints while the indicator is up goes through one place: the
interpreter's `output` closure, which the indicator wraps. It erases the line, prints, and
redraws on the next tick. Today that is the idle-time `errors` event, printed before the
summary when the settle failed, and `notice` lines such as the collector's; each lands on a
line of its own above the moving one, as it would in `cargo`.

Where it lives: an `IndicatorLine` in `SemelCLI`, owned by the interpreter, told
`begin()` by `waitForSettle` before `request(.wait)` and `end()` after, fed by `printEvent`
on `.progress`. It holds the latest record under a lock — the event thread writes, the
timer reads — and knows whether it is enabled from the terminal check done once at start.
The renderer is a pure function from a record and an elapsed time to a string, beside
`SettleSummaryRenderer`, which is what the unit tests read.

## What stays as it is

- Every line the client prints today, in the order it prints it. The indicator is erased
  before any of them and appears in no transcript that is not a terminal's.
- The settle summary, the artifact diff, the idle-time error report and their ordering.
- The `wait` request: it still blocks until the settle and returns nothing. Progress is a
  subscription event, not a reply, so a client that never subscribed sees nothing.
- The exit status of a scripted run: the indicator counts nothing.
- The engine's loop and its pass. The reporter is called at two points that exist already;
  no new pass, no new state beyond reading the tally and the running set.

## Later, not here

- **The dashboard.** The active nodes listed, one per job, with each one's elapsed time;
  the same event, a renderer that owns N lines. After the line has been lived with.
- **A status line at an idle prompt**, which needs the client to own its input line.
- **Why, not what** (B-91): the `running` list names the nodes computing now; which wire
  woke them is the per-node record B-91 keeps.
- **A `watch` verb** that shows the line until a key is pressed, for the person who pushed
  and wants to look without blocking on a settle.

## Cost

A `ProgressRecord` and `ActiveNode` in `SemelProtocol` with the event case and the version
bump; a `progressReporter` on the engine beside `settleReporter`, called from two points in
`processAllNodes`, with a scheduled-row count on `NodeRecord`; the reporter wired in
`RequestHandler.installReporters`; `IndicatorLine`, its renderer and the terminal check in
`SemelCLI`; `waitForSettle` bracketing the wait. Around three hundred lines with the tests.

## Acceptance

1. On the IceCubes packages tree at a terminal, `semel 'base <repo>' 'build Packages'`
   shows a moving line within a second of the push completing, and the line is never more
   than a second stale while the build runs.
2. When the build ends, the screen holds exactly the lines it holds today, and
   `semel 'build Packages' | cat` produces byte-identical output to the same command
   before this change.
3. The counts on the last progress line equal the settle summary's `scheduled`, `computed`
   and `from cache`.
4. `SEMEL_PROGRESS=0` at a terminal shows nothing; the root, engine and end-to-end test
   suites pass unchanged, none of them being a terminal.

## Tests

- `ProgressLineRendererTests`: the line for a record and an elapsed time; singulars; the
  large-number grouping; an empty `running` with `pending` zero renders as the settle it is
  about to become.
- `IndicatorLineTests`: with a recording output, `begin`, three records, a notice line in
  between, `end` — the output is the notice line and nothing else, and the erase sequences
  are where they should be.
- `ConcurrencyTests` or `SettleTests` in SemelCore: `progressReporter` fires with `running`
  never larger than `jobs`, `scheduled` never decreasing within a settle, the last record
  before `settleReporter` having `running` empty, and no record at all from a pass that
  started nothing.
- `DaemonMessagesTests`: the event round-trips; the protocol pin moves to 16.
- `EndToEnd`: unchanged, which is the point — it is not a terminal.
