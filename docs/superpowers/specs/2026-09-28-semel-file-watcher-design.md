# A file watcher that pushes as you save (B-126)

Status: design, then built — see "As built" at the end. A separate program,
`semel-watch`, that observes a tree on disk and pushes what changes into the engine, so
that saving a file is building it.

## The problem

Every push is typed. `push src` after each save, or `build Packages` and a wait, is the
whole edit loop today: the engine keeps the graph warm and settles in seconds on a small
change, but nothing tells it a file changed until a person or a script does. An editor's
save, a `git checkout`, a generator writing into the tree — each is a change the engine
would absorb in the time it takes to read it, and each waits for a command.

The pieces below the command are there. A push of one file is one `pushFile` request with
the bytes and the mode, answered with whether the content changed; a push of many is a
batch (`beginBatch` … `endBatch`) that settles once; `remove` takes a path out; a
subscribed connection receives `settled`, `errors`, `artifacts` and `progress` as the
settle runs. What is missing is the thing that watches the disk and issues them.

## Decisions

- **A separate program, not the engine.** `semel-watch` is a fourth client of `semelserv`
  beside `semel`, `semel-swift` and `semel-clang`, in its own executable target. The engine
  never reads a disk it did not receive through a push — that is what keeps a graph
  independent of where its tree is mounted (2026-09-18 mount-independent outputs) and what
  lets two machines compare cache keys — and a watcher inside it would be the first thing
  to break that. The engine is one per user and a base is per session; a watcher is one per
  tree, started and stopped like an editor.
- **It runs the same commands a person runs, in process.** The watcher links `SemelCLI`
  and drives a `CommandInterpreter` over a `SocketConnection`: `base`, `begin`, `push`,
  `rm`, `commit`, and `export` when asked. "Runs `semel push` automatically" is meant
  literally — the same code path, the same reports, the same follow of a formula's inputs,
  the same idle-time error report — without a process per save. It does not speak
  `DaemonRequest` itself, so a change to what a push does reaches it for free, and a
  transcript of what it did reads like a session.
- **What it watches is what a push would push.** A path is a candidate when
  `ExternalFileSystemLister` would list it — no dot-name at any level, links followed
  except one that points above itself — and it is pushed to the place the same push would
  put it. The watcher and the push must never disagree about which files exist, or a
  build would see a file the watcher will not update, or the reverse. The filter below
  narrows that set; it never widens it.
- **The filter is spelled as the formula spells items.** `--only <pattern>` and
  `--except <pattern>` take the wildcards a formula's for-each takes — `*`, `**`, `?` —
  and read the way `{f: <*.c> except <lua.c>}` reads (B-123): a change is pushed when its
  path matches some `--only` (the default is `**/*`) and no `--except`. Relative to the
  base, as `push` reads its argument. Always excepted, whatever the flags: the export
  destination (`--into`), because a watcher that pushed what it exported would build
  forever, and `semel-out`, where `build` exports by default. Nothing else is excepted by
  default — `Dependencies` is watched, since a re-vendored copy is a change the lock
  check exists to notice (B-06) — and a rule file is not read; the flags are the rule,
  and a project that wants them kept writes them in its own script. Reconsidered when a
  second project needs the same flags.
- **Changes are coalesced into one batch, after two quiet seconds.** An editor saves
  through a temporary file and a rename, a `git checkout` touches hundreds of files, a
  generator writes a folder; each arrives as a burst. The watcher waits until the disk has
  been quiet for two seconds (`--settle-after <ms>` to change it) and then issues one
  batch: `begin`, a `push` per file that exists, an `rm` per path that does not, `commit`.
  The engine settles once, the summary prints once, and a file saved twice in the burst is
  pushed once with its final bytes. A change that arrives while a batch is being pushed
  starts the next quiet interval; nothing is dropped. Two seconds rather than the few
  hundred milliseconds a debounce usually takes: a save that lands mid-checkout, or a
  format-on-save that rewrites the file just saved, is one batch and one settle instead of
  two, and a person who has just saved is reading the editor, not the summary — the
  seconds are paid once per burst, not once per file.
- **A deletion is an `rm`.** A push only adds (B-06's "what remains"), and `rm` is what
  takes a file out. The watcher is the first client that turns the two into a mirror: a
  path that disappears from the disk is removed from `input:` in the same batch, and a
  rename is a removal and a push. A folder that disappears is removed whole. A file the
  watcher cannot read at push time — deleted between the event and the read, or being
  written — is reported by the push as today and picked up by the next event, as the
  `didChange` answer makes a repeated push of the same bytes a no-op.
- **It starts with one full push.** On launch the watcher pushes every watched folder once,
  as `push <folder>` does, so the graph holds the tree as it stands before the first
  change; then it watches. A file the graph has and the disk no longer does is not
  removed by this initial push — that would need a listing of `input:` against the disk,
  which `list` can give — and is left for the first version's "what is not in it".
  `--no-initial` skips the push, for a tree already pushed by hand.
- **FSEvents on macOS, one stream per base.** `FSEventStreamCreate` over the base with
  `kFSEventStreamCreateFlagFileEvents` and `kFSEventStreamCreateFlagNoDefer`, latency
  equal to the quiet interval, on a dispatch queue of the watcher's own. Events are paths
  with flags; the watcher reads each path against the disk when the quiet interval ends
  and decides push or `rm` from what is there, not from the event's flags, which FSEvents
  coalesces and may deliver stale. A `kFSEventStreamEventFlagMustScanSubDirs` or a
  history-done marker is a full push of the subtree it names, which costs one
  `didChange: false` per unchanged file and nothing else. Linux (`inotify`) is out of the
  first version, as Linux is out of Semel today (README: macOS 13 or later).
- **The stream is behind a protocol so the rest is testable without a disk.** `FileEvents`
  yields batches of changed paths; the FSEvents adapter is one conformance, and a test's
  is a queue it fills by hand. The coalescer, the filter and the batch planner take paths
  and a disk (also a protocol, so the test says which paths exist) and return the commands
  to issue, as text: `push a/b.swift`, `rm a/c.swift`. That is the whole watcher minus two
  adapters, and it is what the tests pin.
- **It reports as `semel` reports.** The interpreter's output goes to the watcher's standard
  output: the pushed and removed counts a batch made, then the settle summary and the
  artifact diff the subscription delivers, then the idle-time error report. At a terminal
  the progress line is drawn while a batch's `commit` waits, exactly as `build` draws it,
  and `SEMEL_PROGRESS` governs it as it does there. A line at launch says what is watched
  and what is excepted, so a filter that excepts the file being edited is seen at once.
  Nothing is written anywhere but standard output and standard error.
- **`--into <dir>` exports after every clean settle.** Optional. The edit loop for an app
  is save, build, run: with `--into`, each settle that reports no errors is followed by
  `export <folder> --into <dir>` for each watched folder, as `build` ends; a settle with
  errors exports nothing and the report says why. Without the flag the watcher pushes and
  nothing leaves the engine, which is the right default for a tree whose products are
  read with `cp` or by another tool.
- **It survives the engine, and the engine survives it.** The connection is opened as
  `semel` opens one — starting `semelserv` beside its own executable when none runs — and
  reopened with a short backoff when it drops, re-issuing the pending batch after a full
  push, since a restarted engine may have missed what was pushed while it was away.
  Stopping the watcher (`SIGINT`, `SIGTERM`) ends the stream and the connection and leaves
  the engine and the graph as they are: the next `semel` sees what the watcher pushed.
  Two watchers on one base push the same files twice, harmlessly; the launch line names
  the base so the mistake is visible.

- **The prompt can start one: `watch <folder>`.** `watch` alone keeps its meaning from
  B-95 — the progress line until a key is pressed — and `watch <folder>` starts a
  `semel-watch` for the session's base and that folder, with the flags `build` takes
  (`--into`, and `--only`/`--except` passed through), as a child of the prompt whose
  output is interleaved with the prompt's the way the subscription's events already are.
  `watch` with no watcher running and no folder is the progress line; `unwatch` stops the
  watcher; `quit` stops it too. One watcher per session: a second `watch <folder>` replaces
  the first, and the reply says so. The prompt spawns the executable beside its own, as it
  spawns `semelserv`; it does not link the watcher, so the two stay separately testable
  and a watcher started from a script is the same program as one started from the prompt.
  The two spellings of `watch` share a verb because they share a subject — what the engine
  is doing to this tree, now — and a folder argument is unambiguous; a verb of its own
  would be a second word to learn for the same thing.

## The shape

```
semel-watch <base> [<folder> ...] [--only <pattern>]... [--except <pattern>]...
            [--into <dir>] [--settle-after <ms>] [--no-initial]
```

`<base>` is the directory `push` would take as `base`; `<folder>`s are the folders under
it to watch and push, `.` when none is given — the same argument `build` takes, so a
project built as `build Packages --into ./out` is watched as
`semel-watch . Packages --into ./out`, or, at the prompt of a session whose base is the
tree, as `watch Packages --into ./out`.

```
semel-watch/                     the executable: arguments, signals, the FSEvents adapter
  Sources/SemelWatch/            the library the tests link
    WatchFilter                  --only / --except over paths, with the always-excepted
    ChangeCoalescer              paths in, batches out after the quiet interval
    BatchPlanner                 a batch of paths + a disk → the commands to issue
    FileEvents (protocol)        what a stream yields; FSEventsStream conforms
    Watcher                      owns one interpreter, one stream, runs the loop
  Tests/                         filter, coalescer, planner; the loop over a hand-fed stream
```

The executable is a target of the root package beside `semel`, linking `SemelWatch`,
`SemelCLI` and `SemelProtocol`. `SemelWatch` links `SemelNodeKit` for the lister and the
wildcard matcher and nothing from the engine.

## What one save does

1. FSEvents reports `Sources/App/View.swift` (and, from the editor's temporary file, a
   path the lister would not list, which the filter drops).
2. Two seconds pass with no further event. The coalescer hands the planner one batch of one path.
3. The planner reads the disk: the file exists and matches `--only`; the command is
   `push Sources/App/View.swift`.
4. The interpreter runs `begin`, the push, `commit`. The push answers `didChange: true`;
   the commit waits for the settle, drawing the progress line at a terminal.
5. The subscription delivers the summary and the diff — `changed: output:/App/App` — and
   the watcher prints them. With `--into`, `export` follows.

A `git checkout` is the same with three hundred paths in step 2, some of which no longer
exist and become `rm`s, and one batch in step 4.

## Testing

- `WatchFilterTests`: dot-names at any level are never candidates; a link above itself is
  not followed; `--only` and `--except` compose as the for-each's items and `except` do;
  the export destination and `semel-out` are excepted whatever the flags say.
- `ChangeCoalescerTests`: a burst is one batch; an event during a batch starts the next;
  a path reported twice is in the batch once; the quiet interval is the test's clock, not
  the wall's.
- `BatchPlannerTests`: a path that exists is a push, one that does not is an `rm`, a folder
  that disappeared is one `rm`; a must-rescan flag becomes a push of the subtree.
- `WatcherTests` (root package, in-process server): a hand-fed stream and a temporary
  directory; a file written then reported reaches `input:` with its bytes and mode; a file
  removed then reported is gone from `input:`; two settles for two batches; the launch line
  names what is watched.
- `WatchVerbTests` (root package): `watch` alone is the progress line as before; `watch
  <folder>` spawns the executable with the session's base, the folder and the flags, and
  says so; a second replaces the first; `unwatch` and `quit` stop it. The spawn is behind
  a protocol the test fills with a recorder, so no process is started.
- One end-to-end run in `SemelEndToEndTests` over a fixture: `semel-watch` as a process,
  a real FSEvents stream, a file edited on disk, the product changed within the harness's
  timeout. The one place the adapter is exercised.

## What is not in the first version

- **Deletions the initial push cannot see.** A file removed from disk while no watcher ran
  stays in `input:` until an `rm`; the initial push adds and never subtracts. The fix is a
  listing of `input:` against the disk at launch, and it belongs with the same fix for
  `build`, which has the same gap. (Settled otherwise on 2026-10-04 — see "Decided
  2026-10-04" at the end.)
- **A rule file.** The flags are the rule; a project that wants them kept writes them in
  its own script.
- **Linux.** `inotify` is a second conformance of `FileEvents`, when Semel runs there.
- **Watching the engine's side.** The watcher pushes; it does not react to `artifacts` by
  running anything, and it does not restart a program that the export replaced. That is a
  runner, and a runner is a different program.

## Decided on review (2026-09-28)

- The prompt starts it: `watch <folder>`, above. The verb spawns the program and does not
  absorb it, so a second terminal remains the other honest interface.
- The quiet interval is two seconds, above, and `--settle-after` is for measuring
  another; the default is not to be tuned per project.

## As built (2026-10-01)

Built as above; where the code and the design differed, or the design left a choice, this
is what was done.

- **The planner's commands are typed.** `BatchPlanner` returns `WatchCommand.push(Path)`
  and `.remove(Path)`, which print as `push a/b.swift` and `rm a/c.swift` for a test and a
  reader; nothing between the planner and the interpreter is text read back. The watcher
  gives the interpreter each command as its words (`handleCommand(verb:arguments:)`), so
  a path holding a space is one argument and no tokenizer reads it.
- **One `push` and one `rm` per batch.** `push` and `rm` now take several paths — one
  batch, one work list, one report — so a batch is `begin`, one `rm` of everything that
  went, one `push` of everything that came or changed, `commit`, and the pushed and
  removed counts are the push's own report: each path named up to twenty, counted beyond.
- **The disk protocol is the lister's.** The planner reads the disk through
  `FileWildcardMatcherInput`, asking the matcher for the exact path, so what it sees is
  what `push` sees — dot-named folders, links above themselves — and a test's disk is a
  lister holding the paths it names. Each folder is listed once per plan.
- **A removal needs the graph to hold the path.** A third protocol, `InputHoldings`,
  answered by the interpreter's `inputHolds`: an editor's temporary file that came and
  went inside one quiet interval was never pushed, and an `rm` of it would be an error
  about nothing. A folder that went is one `rm` of the highest vanished folder below its
  watched root. A rescan of a path no longer on disk is planned as a change, so it
  removes; the initial push still only adds, since every root exists at launch.
- **Dot-named files.** B-77 item 5 landed after this design: a push takes a dot-named
  file named exactly. The watcher takes one when the graph already holds it, or when an
  `--only` names it exactly (`--only app/.all-contributorsrc`), never from a wildcard;
  nothing below a dot-named folder is ever a candidate.
- **The follow.** `push` does not follow a formula's inputs — `build` does — so the
  interpreter's follow is public (`followSources(neededBy:)`), and the watcher runs it
  after each `commit`. What it pushes from outside the watched folders — the C fixture's
  `../semel.machine.config` — is watched from then on.
- **Reports as `build` makes them.** A batch runs inside `holdingReports`, so its settles
  print as one summary with the net artifact diff, after the follow, rather than a failing
  line for the source the follow is about to push. Then, when the graph holds errors, the
  watcher runs `errors`; with `--into` it exports only when it holds none. The decision
  is the whole graph's, through `graphHasErrors`, not the settle event's: that event names
  only what newly failed.
- **`--no-reports`.** The prompt starts its watcher with it, and the watcher then neither
  subscribes nor prints `errors`: events go to every subscribed connection, and the
  prompt, subscribed already, prints the summary, the diff and the error report itself.
  Without it each settle printed twice into one terminal. The cost is that the prompt's
  reports are not held, so a followed source is reported missing once before it is pushed.
- **The base as a folder.** `push .` names nothing — the matcher has no segment to
  match — so the base is planned by its children; `export .` now exports every product.
- **Arguments in the library.** `WatchConfiguration.parse` reads them, so they are tested;
  the executable holds `main`, the signals and `FSEventsStream`. SIGINT and SIGTERM stop
  the stream; a batch under way gets two seconds to finish its settle.
- **FSEvents.** Dropped-event flags rescan as must-scan-subdirectories does. Paths are
  made relative to the base as the kernel spells it (`F_GETPATH`), compared without case;
  an event for the base itself is dropped unless it asks for a rescan.
- **The prompt.** `watch` alone stays the progress line whether or not a watcher runs.
  The folder is read as `push` reads one, from the session's current directory; `--into`
  as `export` reads one. A watcher that ended by itself is said to have when `unwatch`
  finds it. The end of a script or of standard input stops it, as `quit` does.
- **Tests.** The root package's test classes are on `XCTestCase`, isolating the globals by
  hand: `SemelCoreTestCase` lives in the engine package's own test target, which nothing
  in the root package can depend on.
- **The code, not the design.** A push of a folder no longer sends one `pushFile` per
  file: it asks for the server's content roots first and sends only what differs (B-132).
  The removal request is `remove(pattern:)`. `build` exports by default into
  `<base>/semel-out/<folder>`, as the design says.
- **Measured.** The end-to-end run over `EndToEnd/Fixtures/c` takes 2.2 s from writing
  the file to the settle summary, two of them the quiet interval.

## Decided 2026-10-04: a push only adds, and the watcher removes with `rm`

The first "what is not in it" put the deletions the initial push cannot see with "the same
fix for `build`". There is no such fix. `push <folder>` and `build` never remove from
`input:` what the disk no longer has: a push that subtracted would make one command mean
two things — "send these" and "make the graph look like this" — and what makes a mirror
atomic is the batch, not the push. A removal is an explicit `rm`, and removals that must
land with pushes are wrapped in `begin` … `commit`, so the engine settles once over the
whole change.

The watcher is the client that mirrors a disk, so it makes those removals itself:

- **The initial push is an initial batch.** `begin`; for each watched folder, the paths
  `input:` holds below it, asked of the server as one listing (`list <folder>/**`, which
  streams), compared with what a push of the folder would push — the lister's rule,
  `--only` and `--except`, a dot-named file when the graph holds it; one `rm` of every
  held path the disk lacks, the highest folder that went whole when everything held below
  it goes; the push of each watched folder; `commit`. One settle. The listing is a second
  question on `InputHoldings` (`holdings(below:)`), answered by the interpreter's
  `inputHoldings(below:)`, so the planner reads typed entries and no text.
- **What the filter excepts is kept.** A held path the disk lacks and the filter does not
  admit is left in `input:` — a narrowing filter is not a request to delete — and a folder
  holding one is removed around it, path by path. The launch line counts both: `removing
  2 paths the disk no longer has`, `keeping 1 path the disk no longer has, which the
  filter excepts`.
- **Only the watched folders.** Nothing outside them is compared, including a source the
  follow pushed from beside them (`../semel.machine.config`): it is watched once followed,
  but the graph's copy is not this launch's to delete.
- **A reconnection mirrors too.** The full push after the engine comes back is the same
  comparison, since an engine that restarted may have missed a removal as well as a push.
- **`--no-initial`** skips the whole batch, removals and push alike.
