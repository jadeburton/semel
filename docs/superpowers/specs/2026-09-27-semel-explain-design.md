# Explain: what the last settle did to a product, and why (B-91)

Status: design, written before the code; the "As built" section at the end says what
changed on the way. Companion to the 2026-09-27 build progress design, which added the
last message the same way: engine reporter, `RequestHandler`, `DaemonMessages`, a verb in
`EnginePlugin`, a renderer.

## The problem

Each settle reports its totals — `✅ 9 nodes scheduled, 8 computed, 1 from cache, 0
errors` — and the artifact diff under them names the products that moved. Neither says
*which* nine nodes, nor what woke them. "Why did this rebuild?" is the first question
anyone asks a build system whose promise is *never twice*, and the tutorial answers it
today in prose, by reasoning about the graph: "the project finder and the include finder,
then one preprocessor and one compiler…". The engine knows the answer and throws it away.

`SettleTally` already keeps the ids of the nodes a settle computed and the ones the cache
answered, and discards them once the totals are taken. What woke each node is known for an
instant in `NodeRecord.writeToOutputPort`: a port whose value changed schedules every
consumer wired to it, and that loop has the source node, its port, the wire's name and
the consumer in hand. Nothing records it.

## Decisions

- **The engine keeps one record: the last settle's.** Per node, whether it computed or the
  cache answered it, and the wires whose writes woke it. In memory, replaced whole when
  the next settle that did work is reported. Not a history: the question is "why did
  *that* rebuild", asked right after it.
- **Replaced when the next settle is reported, not when it starts.** A record that grows
  while a build runs answers `explain` mid-build with half a settle, which reads as an
  answer and is not one. The finished record stays readable until a newer finished one
  replaces it. A settle that scheduled nothing replaces nothing, as it reports nothing.
- **A wake says whether the value really moved.** A port write schedules consumers when
  the new row differs from the old one — but by then the old one is usually `pending`,
  written by the cascade a moment earlier, so "differs" is true of nearly every write.
  The record keeps, per port, the value it held when the settle began — captured on the
  first write to that port in the settle — and a wake compares the new value with that.
  So a compiler that ran and produced the same object says *unchanged* to the linker it
  woke, and a linker the cache then answered is explained by it.
- **Not persisted.** The record describes a moment of this process: node ids the
  collector may reuse, a cascade the next settle overwrites. A graph that outlives a
  restart outlives it without a settle in progress, and there is nothing to explain until
  the next one. Persisting it would put a write per port write into the database on the
  hottest path the engine has, to answer a question about a moment that has passed. A
  restart forgets it, and `explain` says so rather than printing "not touched".
- **The server walks; the client draws.** The server resolves the path, walks upstream
  through the record and returns typed records — labels, outcomes, causes with indexes
  into the same list. The client turns them into indented lines. Nothing crosses as text
  the other side parses: the label is a name for a person, and every decision is made on
  an enum.
- **The walk follows the wires that changed.** From the product, upstream through every
  wake whose value moved, was wired or was unwired, to the sources a push changed. A wake
  that brought an unchanged value is named on its consumer's line and counted, but not
  followed: it says why a node was woken, not why anything was rebuilt. (Revised when the
  first real run disagreed — see "As built".)
- **Bounded, and the bound is in the reply.** At most 40 nodes, 16 wires deep, and 10
  causes named per node; the reply says how many nodes the walk left out and what the
  bounds were, so the renderer can say "and 312 more". A cold build changes everything,
  and an answer that lists the whole graph is `debug`, not `explain`.

## The record

```
SettleRecord                         the last settle, finished
    scheduled:      Set<node>        every node the settle fetched as scheduled
    outcomes:       [node: Outcome]  computed | fromCache, for each that produced a result
    created:        Set<node>        nodes that did not exist when the settle began
    wakes:          [node: [Wake]]   per consumer, the wires that scheduled it, deduplicated
    changedSources: Set<node>        nodes that did not run whose value moved: a push

Wake
    fromNodeID, fromPort, toPort, wireName    the wire, as symbols
    change: changed | connected | disconnected | unchanged
```

Collected by a `SettleRecorder` the engine owns, under a lock of its own: a push writes
ports from a connection's thread while the loop writes them from its task.

- `writeToOutputPort` asks the recorder for the port's value at settle start, handing it
  the row it is about to replace; the first ask in a settle keeps that row. When the write
  schedules consumers, each gets a wake whose `change` compares the new value with the
  kept one. A kept `pending` is a value nobody knows, and compares as changed.
- `Wire.connectWire` and `deleteWire` add `connected` and `disconnected` wakes where they
  schedule the consumer; `NodeRecord.createNode` notes the node as created.
- `reportSettleSummary` finishes the record from the tally's three sets: the wakes whose
  consumer the settle scheduled move into it, and any others — a push that landed between
  the pass ending and the report — stay for the next settle, which is the one they woke.

A wake is recorded when the write is made, inside whatever transaction made it; one that
rolls back leaves its wake behind. The record is a diagnostic, and a wire named as having
woken a node that then did not run is the most such a rollback can do.

## The command

```
explain <path>        (also: why)
```

A path as `ls` and `cp` take one: `output:/hello/hello` or `input:/hello/src/main.c` with
the file system named, `-o`/`-i` before it, or relative to the session's current directory
and file system. The client resolves it — `..` never reaches the server — and sends
`DaemonRequest.explain(fileSystem:path:)`.

The server finds the node at the path, or answers `pathNotFound` naming it; with no
record since the server started it answers an explanation of nil. Otherwise it walks,
breadth first, from the node through the changed wakes, and answers:

```
Explanation
    nodes:        [ExplainedNode]   the one asked about first, then in walk order
    omittedNodes: Int               reached through a changed wire and left out by a bound
    nodeLimit:    Int
    depthLimit:   Int

ExplainedNode
    label:          String          ErrorReport.label: `ClangCompiler #40 'input:/hello/src/main.c'`
    outcome:        computed | fromCache | notRun | changed | untouched
    isNew:          Bool            created by this settle
    causes:         [ExplainedCause]  changed first, then by port and wire name
    unlistedCauses: Int             beyond the ten named

ExplainedCause
    port, wire:  String             the consumer's input port and the wire's name
    change:      changed | unchanged | connected | disconnected
    sourceLabel: String
    source:      Int?               index into `nodes`, when the walk reached it
```

`notRun` is a node the settle woke that produced nothing — an input not ready.
`changed` is a node that did not run and whose value moved: a pushed file, a folder's
manifest. `untouched` is the answer for a product the settle never reached.

The reply travels in the JSON section. `check` and `debug` put theirs in the body because
their size follows the graph's; this one's follows the bounds — forty nodes of ten causes
each is tens of kilobytes, far below the section's megabyte.

## Rendering

One line per node, indented under the node its changed wire reached; a node reached twice
is printed once and named as "see above" after that:

```
OutputFile #62 'output:/hello/hello' — computed: input 'hello' changed
  ClangLinker #44 — computed: objects 'hello2.o' changed; 2 inputs unchanged
    ClangCompiler #41 'input:/hello/src/hello2.c' — computed: input 'hello2.c' changed
      ClangPreprocessor #38 'input:/hello/src/hello2.c' — computed: input 'hello2.c' changed
        StaticFile #12 'input:/hello/src/hello2.c' — changed
```

(Illustrative; the tutorial quotes a real run.) A product the settle did not reach is one
line, `… — not touched by the last settle`. No record is one line saying the server has
settled nothing since it started, and that a restart forgets the record. A path not in
the graph is an error naming it. A walk that stopped at a bound ends with "… and N more
upstream".

## What stays as it is

- The settle summary, the artifact diff, the error report, progress, and their order.
- The engine's pass. The recorder is called from the write path the pass already takes;
  the tally keeps its three sets and hands them over instead of dropping them.
- Nothing is written to the database, and the graph's schema does not change.

## Cost

A lock and a dictionary insert per port write, and one per wake; the memory of one
settle's wakes and first-written ports, a few hundred kilobytes for a cold build of a
thousand-node graph. The walk reads only the record and the labels of the nodes it
returns. `SettleRecord`, `SettleRecorder` and `SettleExplanation` in `SemelCore`; the
request, reply and three record types in `SemelProtocol`, with `ProtocolVersion.current`
16 → 17; the verb, a renderer and a help entry in `SemelCLI`. Around six hundred lines
with the tests.

## Acceptance

1. In the tutorial's `hello`, after editing `hello2.c` and building, `explain
   output:/hello/hello` names the linker, one compiler and one preprocessor as computed,
   `hello2.c` as the changed source, and not the other two chains.
2. After undoing the edit, the same command names the same chain as answered from the
   cache.
3. `explain output:/hello/config.txt` after either says it was not touched.
4. After a restart of the server, `explain` says no settle has been recorded.

## Tests

- `SettleRecordTests` (engine): on a pushed file, a `ConfigFilter` and a `SampleTool`, the
  record after a settle names which nodes ran and which the cache answered, and which wire
  woke each and whether its value moved; the next settle replaces it; a settle that
  scheduled nothing does not; the explanation's walk follows changed wires only, says
  `untouched` for a node the settle never reached, and stops at its bounds with the count.
- `RequestHandlerTests` (server): `explain` over a real in-memory graph returns the
  records, `pathNotFound` for a path not in the graph, nil before any settle.
- `ExplanationRendererTests` (client): the lines from records — the tree, "see above",
  the unchanged count, the bound, the untouched and unrecorded answers.
- `EnginePluginTests` (client): the verb over `RecordingConnection` sends the resolved
  path — named, relative, `-o` — and `why` is the same verb.
- `HelpTests`: `help` names `explain`; a README row for every help entry.
- `MessageJSONTests`: the request and reply round-trip; the pin moves to 17.

## As built (2026-09-27)

Built as designed, with these particulars:

- **The record** is `SettleRecord` in `SemelCore`, collected by `SettleRecorder`, which the
  engine owns as `settleRecorder` and exposes as `BuildEngine.lastSettleRecord`. The three
  hooks are where the design put them: `writeToOutputPort` (the value at settle start and
  the wake), `connectWire` and `deleteWire` (`connected`, `disconnected`), and
  `NodeRecord.createNode` (`created`). `reportSettleSummary` finishes the record from the
  tally, before the settle reporter runs. Wakes on one wire fold into the strongest change
  they brought, in the order changed, connected, disconnected, unchanged.
- **The walk** is `SettleExplanation` in `SemelCore`, with `BuildEngine.explain(nodeID:)`
  reading its own bounds — 40 nodes, 16 wires deep, 10 causes a node — rather than taking
  them as default arguments, which would fold the numbers into the caller (AGENTS.md).
- **The rule for which wires to follow changed after the first run on the tutorial's
  `hello`.** Its fourth experiment — a setting only the linker reads — relinks to the same
  bytes, so the product is woken by an *unchanged* value, is rebuilt all the same, and the
  walk as designed stopped at it: `computed: 2 inputs unchanged`, and nothing about why.
  The walk now goes up every wire into a node the settle touched, unchanged ones included,
  from any node that ran; from a node the cache answered, only up the wires that brought
  something new, since nothing new reached it on the others. And never into a node the
  settle did not touch: a new include finder is wired to a header nothing changed, and
  walking into it printed "not touched by the last settle" under a node that had run.
  `SettleRecordTests` and `ExplainRequestTests` hold both halves of the rule.
- **The request** carries the file system beside the path,
  `DaemonRequest.explain(fileSystem:path:)`, as `fetch` and `list` do; `explain` takes
  `input:` paths too, which answers whether a push changed a source. The reply is
  `DaemonResponse.explain(explanation: Explanation?)`, and the records are `Explanation`,
  `ExplainedNode` and `ExplainedCause`. `ProtocolVersion.current` is 17.
- **The client** has the verb in `EnginePlugin` (`explain`, `why`), resolving the argument
  in `explainTarget` — a named file system from its root, `-o`/`-i` from the root, else the
  session's current file system and directory — and `ExplanationRenderer` beside the other
  renderers. A node reached by two wires from one source — a product's value and its
  metadata both come from the linker — is one child, not two.
- **What a real run prints**, the tutorial's fourth experiment on a fresh home:

```
OutputFile #18 'output:/hello/hello' — computed: 2 inputs unchanged
  ClangLinker #19 — computed: configuration 'wire0' changed; 3 inputs unchanged
    Configuration #20 — computed: base 'wire0' changed
      ConfigFilter #21 — computed: input 'wire0' changed
        ConfigMerger #22 — computed: override 'wire0' changed
          StaticFile #6 'input:/hello/semel.config' — changed
    ClangCompiler #23 — from cache: 2 inputs unchanged
    ClangCompiler #27 — from cache: 2 inputs unchanged
    ClangCompiler #29 — from cache: 2 inputs unchanged
```

  The acceptance list held: after editing `hello2.c` the chain is the linker, one
  compiler, one preprocessor and the file, all computed; undone, the same chain from the
  cache; `config.txt` not touched; after `semel stop`, no record.
- **Not built:** a history of settles, and naming a node's work in its own vocabulary
  ("relinked", "recompiled") — the node types would have to say it, and a generic
  "computed" is what every type can be held to. A formula's wire names show as they are
  stored: the prelude's settings wires are `wire0`.
