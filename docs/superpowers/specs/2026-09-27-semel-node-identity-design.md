# Node identity: a hash one level deep, not a spec spelled out whole (B-115)

Status: design, for review before any code. Companion to the 2026-09-25 preludes design
and the 2026-09-26 two-file configuration design, whose "As built" sections show the shape
this document will end with.

## The problem

A node's identity is its *graph spec*: its type, its properties, and its static input ports
with, for each named wire, the spec of the node the wire comes from — recursively, to the
sources. The engine stores that text in `Node.graphSpec`, under a UNIQUE index, and finds
a node by rendering a demanded spec to the same canonical text and looking it up.

That is correct, and it grows with the graph rather than with the node. A node shared by
two consumers is written out in full inside both, and inside everything below them.
Measured on the IceCubes packages tree (2,627 nodes): 8.9 MB of spec text, each archive's
`OutputFile` about 1.4 MB and each linker about 690 KB, stored twice because of the index —
some 18 MB of a 33 MB database. And the text is not only stored: `Node.applySpecs` rebuilds
a product's spec from the database and parses the demanded one on every `ProjectBuilder`
pass — thirteen in that cold build — walking shared subgraphs once per product each time.

The text is doing two jobs. It is the node's **identity**, which has to be exact and
comparable; and it is a **description** a person reads in `debug`. Only the first has to
be stored, and it does not have to be spelled out.

## Decisions

- **A node's identity is a hash, one level deep.** It is the hash of the node's own kind,
  its properties, and — for each static input port, for each named wire — the wire's name,
  the *identity* of the node the wire comes from and the output port it comes from. The
  same recursion the text has today, folded as it goes: a Merkle tree over the graph, the
  way B-26's content root is one over a folder. Two demands that render to the same text
  today hash to the same identity, and only those.
- **The identity is what is stored and indexed.** `Node.identity`, 64 hex characters,
  UNIQUE, replaces `Node.graphSpec`. Nothing else about a node is stored for matching.
  2,627 nodes cost about 170 KB and an index of the same, where they cost 18 MB.
- **The identity of a demand is a pure function of its tree.** Computing it needs no
  database: children first, then the node. So comparing a demanded wire with the wire a
  node already has is one hash against one column, and never a rebuild of the current
  subgraph or a walk of the demanded one against it.
- **The description is derived, not stored.** `debug` and `check` render a node's one-level
  form from the row and its wires — type, properties, each static port's wires named with
  the identity they come from — and `check` goes one better than "can this spec be parsed":
  it recomputes each node's identity from its live wires and reports one that no longer
  matches what is stored, which is graph damage nothing detects today.
- **The spec language does not change, and it is for people.** A formula, a prelude and a
  converter's emitted text still say `ClangCompiler(configuration: [...], input:
  [...]).output`, and the formula parser still turns that into trees. What changes is what
  the engine keeps and compares — and what components hand each other, which is trees and
  never text (below).

## What the hash is taken of

```
identity(node) = sha256 of
    kind                                  the type's stable number, not its Swift name
    for each property, sorted by key:     key, value
    for each static port, sorted by name:
        for each wire, sorted by name:    wire name, identity(source node), source output port
```

Each field length-framed, so no value can run into the next — the discipline
`FolderContentRoot`'s document keeps, and for the same reason: an identity outlives the
release that computed it, so every byte of what it hashes has to be a decision.

Two choices inside that shape:

- **`kind`, not the type name.** The type name is what a spec *says*; the kind is what a
  stored node *is* — "how a node stored in the database finds its Swift type again", the
  tutorial's words — and it is assigned once. Hashing the name would keep today's rule that
  renaming a node type changes the identity of every node below it; hashing the kind makes
  a rename what it should be, a change to source. The description renders the name from
  the kind. A spec that names a type this Semel does not link has no identity and cannot be
  matched or created, which is what already happens to it at creation.
- **Static ports only**, as today. A dynamic port's wires are what the node itself demands
  while it runs, and folding them in would move a node's identity on every pass.

## Where the text was read, and what reads there now

| Today | With identities |
|---|---|
| `findMatchingNode`: render the demand, `select(graphSpec:)` | hash the demand, `select(identity:)` |
| `createNode`: store the rendered text, or rebuild it from the graph when no text was given | compute the identity from the children just created; the "patch it in afterwards" path goes, since a node's identity is known before its row is |
| `applySpecs` step 3: `buildFromWire` the current subgraph, parse the demand, `expectTopologyMatch`, fall back to a second lookup on a false mismatch | identity of the demand equals the identity on the wire's source, and the ports agree — or it does not; no rebuild, no topology walk, no fallback |
| `GraphCheck.graphSpecs`: the text parses and names a linked type | the stored identity equals one recomputed from the row and its wires, and the kind is linked |
| `DebugPrint`: parse and pretty-print the stored text | render one level from the row and its wires |
| `GraphSpecNode.namesOnlyRegisteredTypes(spec:)` on stored text | asked of the kind on the row |

`expectTopologyMatch` was port-order- and wire-order-independent by construction, and
tolerated extra ports on the current node (the dynamic ones). The hash keeps both: it is
taken over sorted static ports and sorted wires, and over static ports only.

## The demanded side: trees, not text — everywhere

The other half of the measured cost is the demanded spec. `ProjectBuilder` renders each
product's tree to text and hands it to `applySpecs` in `inputWireSpecs`, which parses it
back — 1.4 MB per archive, per pass. The tree already exists in the builder; the text is a
transport, and it is not the only place one is used as one. Counted on 2026-09-27:
eighteen sites in the sources assemble a spec by string interpolation —
`"StaticFile(path: '\(path)').output"` and its kin in `ProjectBuilder`, `ProjectFinder`,
`FolderTreeWalk`, `ClangPreprocessor`, `SwiftCompiler`, `SwiftLinker`,
`XcodeProjectConverter` — and nine call `GraphSpecNode.parse` to read such strings back,
`ProjectBuilder` among them, which renders a tree it holds into a string and parses that
string in the same function. Every one of those is a place a quoting mistake compiles and
a parse failure is found at run time.

The rule, then, is not "the builder gets a faster path": **text is for what a person writes
or reads; between components, trees.** A formula is text because a person writes it; an
emitted formula is text because it is a formula; `debug`'s output is text because a person
reads it. Nothing else is.

- **`ProcessOutput.inputWireSpecs` carries trees**: `[port: [wire: GraphSpecNode]]`, with
  no string form. `applySpecs` hashes a demand without a parse, and there is exactly one
  parse site left in the engine — the formula parser.
- **The spec model moves to `SemelNodeKit`**, public, so a plugin can build one:
  `GraphSpec.swift` is already "pure model, serialisation and parser, no database access",
  and the applier — matching, creating, wiring — stays in `SemelCore`. Building a tree is
  typed by the node type rather than by its name — `GraphSpecNode(StaticFile.self,
  properties: ["path": path]).port(StaticFile.outputPort)` — which gives the tree its kind
  directly, spells port names from the constants the node already declares, and cannot
  misquote a path. Convenience constructors cover the shapes that recur (`.staticFile(at:)`,
  `.folder(at:).manifest`); a tree parsed from a formula carries a type *name* and resolves
  it to a kind through the registry, as creation does today.
- **A cache entry stores its demanded specs as canonical text.** That is the one place the
  rendering is right for a tree: an entry is written once and diffed by a person when two
  builds disagree, and the text is what `asString` was for.
- **A scan test keeps it so**, in the manner of `DictionaryOrderTests`: a spec assembled as
  a string literal in `Sources`, or a call to `GraphSpecNode.parse` outside the formula
  parser, fails the build with the file and line.

This comes with the identity change rather than after it because it is the same seam: once
a demand is a hash of a tree, handing over the tree is the interface, and a string was only
ever a tree in disguise.

## What stays as it is

- **The spec language** and every text a person writes or reads in it: formulas, preludes,
  emitted formulas, the tests that compare `asString` renderings of parsed trees
  (`ClangPreludeTests`, `AppPreludeTests`).
- **Cache keys.** They are taken of a node's type, version, properties and input *values*,
  not of specs; an identity change does not move a single cache entry.
- **Zombies.** A node pending deletion still holds its identity, and a fresh demand for the
  same node still finds it rather than creating a duplicate — the UNIQUE index is the same
  guard on a shorter column.
- **`outputs` in a spec** — parsed, stored, never matched today — stay out of the identity,
  as they are out of the text's matching today.

## Later, not here

- **A per-pass memo of demanded identities.** A product tree shared by several products is
  hashed once per product per pass. Hashing is cheap next to what the parse cost; if it
  shows up, a memo keyed by tree suffices.
- **Identity as a wire-value key.** Nothing about cache entries or artifact snapshots
  changes here; a later design may find the identity a better handle than a node id for
  reconciling two peers' graphs (B-06), since it is path-independent and stable.

## Cost

- **`Semel.version` bump** — a stored graph is rebuilt, as for every change to what a
  column means (B-29, B-44, 0.1.7). The cache survives.
- **Every reader of the column** listed above, and the 23 test files that read
  `.graphSpec` or select by it (43 sites), most of which assert that a demanded node was
  found again — which they will assert against the identity.
- **`GraphSpec.swift`'s `buildFromNode`/`buildFromWire`** shrink to one level;
  `expectTopologyMatch` goes.
- **The eighteen string sites and nine parse sites** become tree constructions; the spec
  model moves packages; every test fake that returns `inputWireSpecs` strings returns
  trees.

## Acceptance

1. On the IceCubes packages tree, `Node` holds no spec text; the database is smaller by
   what the column and its index held (about 18 MB of 33), measured before and after.
2. A cold build's `ProjectBuilder` passes no longer parse a product's spec or rebuild the
   current one; the time of a nothing-changed rebuild (18.7 s before B-112/113) is
   measured before and after.
3. Every demand that found a node before finds the same node: the applier's, the
   preludes', the converters' and the builder's tests pass against identities.
4. `check` reports a node whose stored identity does not match one recomputed from its
   wires, and a test damages a wire to prove it.
5. Renaming a node type (in a test, by registering the same kind under another name)
   leaves every identity unchanged.
6. `debug` shows each node's one-level form: type, properties, and each static port's
   wires with the first eight characters of the identity they come from.
7. No source file assembles a spec as a string or parses one outside the formula parser:
   the scan test passes, and `GraphSpecNode.parse` has one caller.
8. A cache entry written before and after round-trips its demanded specs.

## Decisions taken in review (2026-09-27)

- **Identities are truncated to eight hex characters in `debug`.** A collision is
  possible only inside a dump, and the full value is on the node's row for anyone who
  needs it.
- **Trees everywhere, not a builder-only path.** The author's reason, recorded here because
  it is the design's: there is already too much use of hard-coded strings in the code that
  then have to be parsed. A builder-only tree form would have kept eighteen such sites and
  blessed the pattern; the rule above — text for people, trees between components — is the
  one worth enforcing, and the scan test is what enforces it.

## As built (2026-09-27)

In three layers, each green on its own: the model moved to `SemelNodeKit` (A); the
identity replaced the text (B); trees replaced strings between components (C). What
differs from the text above:

- **A port with no wires is not part of the identity.** A demanded tree names only the
  ports it wires; a node's row has every port its type declares. The hash skips wireless
  ports so the two agree — found when `check` reported a freshly created leaf as stale.
- **`check` recomputes from what it has already read**, the nodes and wires in hand, and
  runs only when both tables were readable: a per-node query would have gone back to a
  table the walk had found unreadable, which is a fatal volume error, not a finding.
- **A cache entry stores its demanded specs as trees**, `GraphSpecNode` being `Codable`,
  not as canonical text: reading text back would have been the second parse site the rule
  forbids. Entries written before this miss and are rewritten, as a changed entry shape
  always has.
- **`buildOutput(reason:)` describes no wires.** It rebuilt full spec text for every
  dynamic wire so that `applySpecs` would not delete them — but `writeToOutputs` applies
  specs only to the ports an output names, so naming none keeps them all. The rebuild was
  never load-bearing, and identities could not have done it anyway.
- **Engine node names for toolchains.** A plugin cannot import `StaticFile`, `Folder`,
  `Configuration`, `ConfigFilter` or `ConfigMerger`, so it builds their trees through
  `FileSystemNodes` and `SettingsNodes` — names and ports as constants in the node kit,
  pinned to the types by `NodeNameConstantsTests`. The Swift converter's demanded package
  reader is built this way; its emitted *formula* keeps the same shape as text.
- **`ProjectBuilderPlugin.spec(forEntry:inFolder:)` returns a tree**, and the parser's
  `includeReader` is handed the included node's tree, its rendering being the wire's name.
- **The finding is `staleIdentity`** (protocol 15), and it covers a node with no identity,
  one whose kind is unlinked is `unlinkedNodeType`, and one whose recomputation differs.
- **The scan** allows spec text in the files that write formulas — the three preludes, the
  two formula emitters, prepare's generated files, and the parser — and nowhere else; the
  eighteen sites and the nine parses are gone, and the tests that asserted on spec text
  render trees to compare.
- **Not measured here:** acceptance items 1 and 2 (the IceCubes database size and the
  nothing-changed rebuild) want the external project, which the fixtures do not stand in
  for; the next performance pass takes them.
