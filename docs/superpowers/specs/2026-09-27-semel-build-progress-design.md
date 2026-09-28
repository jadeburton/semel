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

## As built (2026-09-27)

Built as designed, with these particulars:

- **The event** is `DaemonEvent.progress(record:)` carrying `ProgressRecord` and
  `ActiveNode` in `SemelProtocol`; `ProtocolVersion.current` is 16. The engine's own type
  is `ProgressReport` with `ActiveNodeDescription` in `SemelCore`, handed to
  `BuildEngine.progressReporter`; `RequestHandler.installReporters` maps one to the other.
- **The two points** are in `processAllNodes`: after a scheduling round that started at
  least one node, and after every result, once its write is done — so the pending count
  includes what the write scheduled. `pending` is `NodeDataAccess.countScheduled()`, a
  count of the rows a running node has already left. A pass that starts nothing sends
  nothing, and `ProgressReportTests` holds it to that and to the tally's promises.
- **A node's name** is what a report gives it, through `ErrorReport.path(of:database:)`,
  factored out of the report's label: the `path` property, else the project file wired
  to it, else empty. The type name is the registered type's.
- **The client** has `ProgressPolicy` (public, read by `main`), `ProgressLineRenderer`
  and `IndicatorLine` in `ProgressIndicator.swift`. The interpreter owns the line, routes
  `outputMessage` and `outputError` through `interrupting`, and answers two new
  `CommandContext` calls, `settleWaitBegan` and `settleWaitEnded`, which
  `EnginePlugin.waitForSettle` puts around the `.wait` request and nothing else — so the
  `commit` that ends a batch has the line too, through the same function.
- **The mark.** `Mark.working` (`⏳`) is the third mark and the one that says neither good
  nor bad; it is allowed because it never stays on the screen. `MarkTests` pins all three.
- **Redraws** are at most one per 100 ms on events and one per second from a timer; the
  timer exists only between `begin` and `end`. Writes go through C stdio and are flushed,
  so they keep their order with `print`.
- **A defect the first terminal run found.** `ServerConnection` handled every request on
  the connection's own queue, and a `wait` parked that queue until the settle — while the
  events to that client leave through the same queue. Every event the waiting client
  should have read meanwhile, progress and the collector's notice alike, arrived in one
  burst as the wait returned; nobody had noticed because `settled` and the idle-time
  error report arrive at that moment anyway. A `wait` now runs on a thread of its own,
  and `WaitEventsTests` holds a socket client to seeing the slow node running well before
  its wait returns. Measured on the IceCubes graph after a `nudge`: 115 drawings over a
  39 s settle, the first within the first second, and the screen afterwards byte for byte
  the piped output.
- **The `watch` verb** (2026-09-28) is the blocked case spelled as a key: `watch` begins
  the line, waits for a key on standard input with the terminal raw for the wait — echo,
  canonical mode and signals off, so Control-C is a key that ends the watch rather than a
  signal that kills the client with echo off — and ends the line. A key leaves the settle
  running and prints where it stood (`Still settling — …`, the counts without the `⏳`
  or the clock) or `No settle in progress.`. A settle that finishes ends the watch as it
  would end a `wait`: its summary and artifact lines print through `interrupting`, then a
  `.wait` request whose reply lands after them, then `Settled.`. Kept open instead, the
  watch would sit over a finished settle, and the person who began typing their next
  command would lose its first letter to the key that ends it. The terminal is put back
  with `TCSAFLUSH`, so the rest of what was typed after the key does not reach the prompt.
  Standard input not a terminal, the verb says so and returns; a batch open, it refuses
  as `wait` does. The key wait is `KeyReader` on the `CommandContext` —
  `TerminalKeyReader` in the client, a script in `EnginePluginTests` — and polls a tenth
  of a second at a time so the finished settle, counted by the interpreter from the
  `settled` event, is seen. The interpreter also keeps the last `progress` record until
  `settled`, which `settleWaitBegan` now hands the line so that a `wait` or a `watch`
  begun mid-settle draws at once rather than at the next node's start or finish. No
  one-letter alias: `w` is as much `wait` as `watch`.
- **The dashboard** (2026-09-28) is a size of the one setting, not a setting of its own:
  `SEMEL_PROGRESS=full` selects it, unset or `1` (or anything unknown) keeps the line,
  `0` turns both off; `ProgressPolicy.Mode` is `off`, `line` or `dashboard`, decided by
  `modeInThisProcess()` over the same terminal test as before. The frame is the totals
  line and then one line per node in `running`, in start order:
  `   ClangCompiler  input:/cpp/main.cpp.p  4.2 s` — the type padded to the longest type
  shown, the name padded to the longest name and cut from the left with `…` to fit (a
  path's end is what tells two compiles apart), the elapsed time right-aligned, tenths
  under a minute and the line's `1m 32s` above. `ProgressDashboardRenderer` is pure over
  a record, the per-node times and a `TerminalSize`, which is `ioctl(TIOCGWINSZ)` read
  once per drawing, 80 by 24 when standard output will not say.
- **Each node's time is the client's.** The record carries no start times and no ids, so
  `ActiveNodeClock` stamps a node with the time of the first record naming it, keyed by
  type, name and how many of that type and name precede it in the list (two unnamed
  twins are two clocks), and drops the stamp of a node a record no longer names. The
  stamps are taken from every record, waiting or not, so a node already running when a
  `wait` or a `watch` begins shows its real time; line mode keeps none.
- **N lines in place.** The indicator counts the rows its last frame drew. Every redraw
  is one write: carriage return and erase the row the cursor is on, then up-and-erase
  (`ESC[1A ESC[2K`) once for each further row, then the new frame, rows joined by
  newlines and no newline after the last, so a smaller frame leaves nothing of a larger
  one. `interrupting` and `end` erase every row the same way. With one row the sequence
  is the line's `\r ESC[2K`, so the line is the dashboard's one-row case, not a second
  code path. Two things would break the count, and both are prevented: a row wider than
  the terminal wraps into two, so every row is cut to the width less one column (the
  last column leaves some terminals with a wrap pending), counting `⏳` as the two
  columns it takes; and a frame taller than the screen scrolls its first rows out of the
  cursor-up's reach, so the frame is at most the height less two rows, the last node
  line giving way to `and N more`. The totals line, too wide, drops the split of what is
  done before it drops the clock — at 80 columns a large build's line needs it — which
  the line mode now shares, since a wrapped line there left a row behind on every redraw.
- **A name for a node with no path.** Most running nodes had none: a report names a node
  by its `path` or its project file, and a compiler has neither, so the first dashboard
  was a column of `ClangCompiler`s with nothing after them. The engine's progress name
  now falls back to the path-named wire on the node's `input` port — the source a
  preprocessor reads, the `.p` a compiler compiles — as the event section above first
  proposed; a node whose inputs are named otherwise (`ClangIncludeFinder`'s
  `sourceFile`, a linker's object files, a Swift compiler's folder) still has none.
  Error labels are unchanged.
- **Tried by hand** under `script` on `EndToEnd/Fixtures/cpp`, 80 by 24 and 46 by 6: the
  log holds frames of up to nine rows erased with the matching run of up-and-erase
  sequences, the small terminal's frames stop at four rows with `and 5 more`, and the
  final screen, replayed through a minimal terminal, is byte for byte the piped output.
- **Not built:** a status line at an idle prompt, as the *Later* section says. B-95's
  residual in `FUTURE.md` names it.
