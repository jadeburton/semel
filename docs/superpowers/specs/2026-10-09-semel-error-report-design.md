# The error report: a timeless statement of what has no value, and why

Status: design, for review before any code. Follows the 2026-10-09 discussion of the error
report and of Semel as a time-free zone.

## The principle

Inside the engine there is no time. A node is a function of its inputs; a product either
has a value or has none; a cache entry is keyed by content and never by a moment. The
report of what is wrong must speak the same way: it describes the state of the graph —
which function has no value, for which inputs, and what therefore has none either — and
never narrates a run. No "while", no "stopped", no "stale", no "after". A line is a label
and a value, true for as long as the inputs hold.

The report today reads like the engine talking to itself:

```
2 errors across 1 node:

Stopping output:/Packages/libConversations.a:
❌ SwiftCompiler #2510
   · object, swiftmodule:
     swiftc exited with status 1:
     input:/Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' to specified type 'Int'
   · and 22 nodes downstream carry it
```

Every line is true and none is what a person needs. The node type and id, the port names,
the tool's exit status, the engine's path scheme and the count of carriers are all facts
about the machinery. What the person needs is the diagnostic, what it belongs to, and what
is without a value because of it.

## The format

Decided 2026-10-09, the owner's wording:

```
Packages/Models/Sources/Models/Account.swift:201:28: error: cannot convert value of type 'String' to specified type 'Int'
  target: Models
  needed by: libConversations.a, libExplore.a, libLists.a and 2 more

1 error · 5 products without a value · nothing exported
```

- **Line one is the diagnostic**, as the tool wrote it, in `file:line:column: error:` form
  so that terminals, Xcode and VS Code make it a link. The engine's `input:/` prefix is
  rendered as the path on disk, relative to the session's base: a substitution of a known
  prefix at render time, not a parse of the text. A diagnostic with several lines keeps
  them, indented under the first. A tool that failed without a diagnostic has line one
  `swiftc exited with status 1 and said nothing`, which is the one case the status is
  information.
- **Line two names what the failing function belongs to**, with a label saying what kind
  of thing that is: `target: Models` for a compile, `product: libConversations.a` for a
  link, `package: GRDB.swift` for a lock check or a manifest read, `resource:
  Media.xcassets` for a catalog, `formula: Packages/semel.fmla` for a conversion or a
  builder, `project: CodeEdit.xcodeproj` for the Xcode converter. One line, one label.
- **Line three is `needed by:`** with the products that have no value because of it, as
  product names when they are unambiguous and as paths under `output:` when two products
  share a name, up to three named and the rest counted. An error no product reaches says
  `needed by: nothing`. A tree product's entries are named by the tree, `IceCubesApp.app/`.
- **An optional fourth line is the remedy**, only for the error kinds that have one the
  engine can state as a fact: `re-lock with: semel-swift prepare` for a lock mismatch,
  `missing: Sources/Kit (also tried Source/Kit, src/Kit, srcs/Kit)` for a target folder,
  `set: swift.compiler.target` for a setting the tool rejected (which `SettingArgument`
  already finds). Never advice, only the name of the thing to change.
- **The summary line** ends the report and is also what `build` and the watcher print
  alone: `1 error · 5 products without a value · nothing exported`, or `· exported to
  semel-out/Packages` when the export ran, or `· 3 of 5 products exported` when `--into`
  exported what had a value. Counts are of errors and of products; nodes are not counted.
- **Order.** Causes first, each once. An error that reaches several products appears once
  with all of them on its `needed by:` line. Errors carried downstream — a link without
  its object, a compile without its module — are not errors of their own and are not
  listed; they are the `needed by:` of their cause. Causes are ordered by the path on line
  one, so the report is the same for the same graph.
- **`errors <product>`** is the product view: the same blocks, filtered to the causes that
  reach the product, under one heading `libConversations.a has no value because:`. A
  product with a value says `libConversations.a has a value.` and nothing else.
- **`--verbose`** adds, under each block, the engine's facts: `node: SwiftCompiler #2510`,
  `ports: object, swiftmodule`, `carried by: 22 nodes`. Off by default. The same flag on
  `build` and in the watcher's launch arguments.
- **Colour** when standard output is a terminal and `NO_COLOR` is unset, as the progress
  line decides: the diagnostic's `error:` in red, the path bold, the labels dim; no colour
  when piped, so a log is plain text.

The same shape for an engine condition:

```
Dependencies/GRDB.swift differs from its lock: 2 dot-named files the graph holds are not in the lock (.spi.yml, Sources/.swiftlint.yml)
  package: GRDB.swift
  needed by: libConversations.a and 4 more
  re-lock with: semel-swift prepare
```

And for a missing source:

```
Packages/Kit/Sources/Kit has not been pushed
  target: Kit
  needed by: libKit.a
  missing: Sources/Kit (also tried Source/Kit, src/Kit, srcs/Kit)
```

## Where the lines come from: a typed error document

Today a failing node publishes `.noValue(reason: .error(messageDataObjectHash:))`: a hash
of text the node composed. The client cannot tell a diagnostic from a sentence the node
wrote, cannot find the subject, and cannot know whether there is a remedy. So the three
lines cannot be rendered from it without reading the text, which the house rule forbids.

Instead, a node publishes an **error document**: a typed value, interned like a
`TreeManifest` is, carried by the same `.error` reason as the hash of its encoding.

```
ErrorDocument
  diagnostic: Diagnostic        .tool(text, tool)            the tool's output, as written
                                .engine(ErrorCondition)      a typed condition, rendered by the client
  subject:    Subject           .target(name) | .product(path) | .package(name)
                                | .resource(path) | .formula(path) | .project(path)
  remedy:     Remedy?           .relock(package) | .missingFolder(tried: [Path])
                                | .setting(key) | .register(kind) | …
```

- The node is the one that knows the subject: `SwiftCompiler` has the module name,
  `SwiftLinker` the product, `DependencyLockCheck` the package, `AssetCatalogCompiler` the
  catalog, `ProjectBuilder` the formula. Each fills the document where it fills the message
  today, through one helper per shape in `SemelNodeKit` (`ErrorDocument.tool(…)`,
  `.engine(…)`), so a node never writes a sentence.
- `ErrorCondition` is an enum of the engine's conditions that reach a report — the lock
  mismatch with its differing entries, a source not pushed, a target folder missing with
  the folders tried, a port wired twice with the wires, an unregistered kind, a product
  with no producer, a tool not installed, a setting rejected — each with the values its
  sentence needs. The client renders the sentence; the engine never does. New conditions
  are new cases, and a case nobody renders is a compile error in the renderer's `switch`.
- The `errors` reply carries the document, decoded, in each `ErrorRecord` beside the
  products from B-142 (`needed by:`) and the node's facts for `--verbose`. The record no
  longer carries a rendered message; `ProtocolVersion` is bumped and `ErrorRecord`'s field
  is non-optional.
- A document is a value, so it is cached with the node's other outputs and compared like
  one; two runs of the same failing inputs have the same document. A tool's diagnostic
  that embeds the sandbox path is already rewritten to `/semel` by `ToolSandbox`; a
  diagnostic that embeds anything else nondeterministic is the tool's fault and the
  determinism invariant's business, not this design's.
- Every node that publishes an error changes what it publishes, so every such node type
  bumps its `implementationVersion`, per AGENTS.md's rule. One pull request, one sweep.

## What stays

- The typed errors inside the engine (`NodeError`, `GraphSpecApplierError`, the converters'
  errors) are unchanged; the document is what crosses the port, and each of them maps to
  an `ErrorCondition` at the node that catches it.
- `errors` streams (B-137) and groups by product on the server (B-142); the grouping
  becomes the `needed by:` line and the product view.
- The tutorial quotes two failed-build reports; both change in the same commit, as the
  rule for quoted output says.

## Testing

- `ErrorDocumentTests` (SemelNodeKit): the document round-trips through interning; each
  helper fills the subject it is given; a document is equal for equal inputs.
- `ErrorRenderingTests` (root): one test per `ErrorCondition` case and per subject kind
  pinning the exact lines, including `needed by: nothing`, the `and N more` cut, a
  multi-line diagnostic, a silent tool, the summary line in its four forms, and `--verbose`;
  the `input:/` substitution with a base that holds a space; colour on and off.
- `errors <product>` tests update their expected text; the product view's heading.
- The idle-time report, `build`'s and the watcher's summary line: one test each.
- End to end: the C fixture with a deliberate error, the report compared line for line.

## Open for review

- Whether `needed by:` names products by file name or by `output:` path when names are
  unique. Proposed: file name, path only to break a tie.
- Whether `--verbose` is a flag or a `verbose` setting at the prompt that persists for the
  session. Proposed: a flag on `errors` and `build`, and a `watch --verbose`.

## As built (2026-10-10, B-145)

The two open questions were decided as proposed: `needed by:` names products by file name,
with the path under `output:` only where two products of one report share a name; and
`--verbose` is a flag on `errors` and `build`, passed through `watch <folder> --verbose` to
`semel-watch`. Where the code differs from the text above:

- **A subject can be absent.** A condition about the graph rather than about one thing in
  it — a source nobody pushed, an input in error whose cause has been collected — names its
  path on line one, and the block has no subject line. A seventh kind, `source:`, names the
  one file a C preprocess or compile reads, which has no target to name.
- **A node can have several causes.** A converter missing three packages, or holding two
  locks that moved, publishes one document whose diagnostic is `.several([ErrorDocument])`,
  and the report shows each as its own block with its own subject.
- **A condition can carry labelled lines under line one**, before the subject: `lock:`,
  `expected:`, `found:` and `not compared:` for a lock mismatch, `installed:` for a tool
  not installed, `reason:` where the operating system said why. The lock mismatch's line
  one is `<folder> differs from its lock`; what the comparison left out is `not compared:`
  rather than on line one, since none of it is what differs (B-143).
- **Two documents differing only in which subject of one kind they name are one block**,
  its subject line naming each — three compilers missing one machine setting are one error,
  `source: hello/src/hello.c, hello/src/hello2.c, hello/src/main.c`. The engine counts by
  the same key (`ErrorDocument.mergeKey`), so a settle's `N errors` is the number of blocks.
- **The remedies** are `re-lock with:`, `missing:`, `set:` (one key or several: a tool can
  reject two settings at once), `register:` (a kind by number, or a type by name), `write
  with:` for the commands that write the machine file, `vendor with:` for a dependency or an
  artifact `prepare` puts in place, and `delete:` for a stored object whose bytes are not
  its name. `SettingArgument`'s advice sentences are gone; the key is the remedy.
- **The `input:/` substitution drops the prefix.** The input file system's root is the
  base, so a path below it is written relative to it and the base itself is never printed,
  whatever it holds.
- **The summary line with no product short of a value** reads `every product has a value`.
  `build` exports into its default folder only when every product has a value (an error
  needed by nothing), `· exported to semel-out/<folder>`; `build --into` and the watcher's
  `--into` export what has a value, `· 3 of 5 products exported`, or `· nothing exported`
  when nothing has. A build with no errors prints `No errors.` and `Exported N files into
  <dir>` as before. The exit status is non-zero whenever there are errors.
- **Colour** marks the location of a tool's line that holds `: error:` bold and `error:`
  red, the path leading a condition's line bold, and the labels dim; `TERM=dumb` turns it
  off as it turns off the progress line.
- **The engine renders nothing.** `ErrorReport.lines` is gone, and an engine with no server
  reports to nobody. `NodeError.other(message:)` is gone too: every site names a case, and
  an error from outside Semel is published as `.unclassified(type:description:)`, the last
  resort. A plugin refusing an include gives a typed `IncludeRefusal`.
- **A state a node publishes while its demands are on their way** — the converter's
  "waiting for …", the preprocessor's "Still resolving include files" — is
  `.inputsWithoutValue(kind:paths:)`, said as what has no value.
- **The wire.** `ErrorRecord` is one per document, with `ErrorFacts` (the node's type, its
  ids, the ports carrying the document, the carriers) for `--verbose`; `SemelProtocol`
  depends on `SemelNodeKit` to carry the document as the value the node published, protocol
  version 25. `Semel.version` is 0.1.16, since a stored error port's hash named a sentence.
