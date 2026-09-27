# A cache entry's demanded specs as a table, each node once (B-121)

Status: design, then built — see "As built" at the end. Follows the 2026-09-27 node
identity design (B-115), whose identity this table is keyed by.

## The problem

A node that demands wires returns them on `ProcessOutput.inputWireSpecs`: per dynamic input
port, per wire name, the `GraphSpecNode` tree of the node the wire should come from. A
`ProcessCacheEntry` stores those trees so that a hit can wire the graph without running the
node (`loadCachedOutputs`, then `Node.writeToOutputs` and `applySpecs`).

Each tree is the whole graph above its wire, spelled out. A node reached by two paths is
written twice, and in a product builder's demand the settings chain under every compile —
`ConfigMerger`, `ConfigFilter`, `Configuration` — is written once per compile. Measured on
the IceCubes packages tree (2026-09-27, after B-115): the two entries of the project
builder's export output hold 31 of the database's 34 MB, 15.5 MB each; the spec for one
linker output is a tree of some 20,000 nodes in which the settings chain appears 2,668
times and each source file's `StaticFile` twice. gzip takes an entry to 0.2 MB: it is
repetition, not information. The other 252 entries are 2.7 MB together.

The graph does not have this problem, because B-115 made a node's identity a hash one level
deep: a node names its sources by identity, and a shared node is one row. The entry can
store its demand the same way.

## Decisions

- **The stored form is a table of distinct spec nodes, keyed by identity.** A row holds the
  node's type name, its properties, and per static input port its named wires, each naming
  its source by identity and output port. The entry's demands are references into the
  table: per port, per wire name, `(identity, output port)`.
- **The key is the graph's identity.** A row is filed under `NodeIdentity.hash` of its
  kind, properties and wires — the identity `GraphSpecNode.identity()` computes and
  `Node.identity` stores. So a row's key is the identity of the node the applier finds or
  creates for it, a reader of an entry can look a row up in the graph, and two rows are one
  exactly when the graph would make them one node. A hash of the rendered subtree, or a row
  index, would have folded as well and matched nothing.
- **The type is stored by name, not by kind.** The kind is what the identity hashes; the
  name is what a tree carries and what a reader has to check against what this Semel links
  (`namesOnlyRegisteredTypes`) before acting on the entry. A row naming a type this Semel
  does not link makes the entry a miss, as a tree naming one did.
- **The table lives in `SemelNodeKit`, beside `GraphSpec.swift`**, as `GraphSpecTable`:
  pure, no database, like the model it folds. `init(trees:)` folds and `trees()` unfolds.
  The fold hashes each occurrence once, children first — the recursion `identity()` makes —
  and writes each identity once. It walks ports and wires in sorted order, so which
  occurrence of an identity is "first" is the same in every process.
- **A row keeps its first occurrence's order.** Two occurrences of one identity can differ
  only in the order they list properties, ports and wires, which the identity sorts away;
  they are one node, created once, and the row keeps the order of the first one folded —
  the order that node would be wired in. Unfolding gives every occurrence that order.
- **`outputs` is not stored.** A `GraphSpecNode`'s expected outputs are parsed and never
  matched; they are outside the identity, and nothing creates or matches through them. The
  table unfolds to trees with none.
- **A hit unfolds the table into trees**, and `writeToOutputs` applies them as it applies a
  node's own output. Unfolding builds each identity's tree once and shares it: a tree's
  arrays are copy-on-write, so the thousands of occurrences of a settings chain are one
  value in memory as they are one row on disk. An applier that walked the table directly
  would also skip hashing each unfolded tree again in `applySpecs`; that changes what a hit
  hands `writeToOutputs` — a table instead of a `ProcessOutput`, through `ComputeResult`
  and both hit paths — and the applier's find-or-create, which is a change to the applier
  rather than to the cache. It is this item's residual.
- **A damaged table is a miss.** A reference to a row the table does not hold, or a row
  among its own sources, fails to unfold and the entry is not handed back. A fold writes
  neither, but a stored table is read as it stands and its keys are not re-verified.

## What changes

- **`ProcessCacheEntry`**: `inputWireSpecs: [String: [String: GraphSpecNode]]` becomes
  `specTable: GraphSpecTable`. A renamed, non-optional field: an entry written before fails
  to decode and is a miss, and the build that misses rewrites it — AGENTS.md's rule for a
  changed entry shape, and no decoding of the old one (no backwards compatibility before
  the first public release). `holdsAnUnreadableEntry` already lets a build under the
  storage floor replace such a row.
- **`saveCacheForAllInputsAndOutputs`** folds the output's trees into the table.
- **`loadCachedOutputs`** asks `namesOnlyRegisteredTypes` of the table's rows — once per
  distinct node instead of once per occurrence — and unfolds the table, a failure to
  unfold being a miss, before refreshing the row's timestamp.

## What stays

- **The cache key.** It is taken of the node's type, implementation version, properties,
  fingerprint and input values (`CacheKeyMaterial`); no spec is in it. Every key is the
  same before and after, and an entry misses once only because its content no longer
  decodes.
- **No `implementationVersion` bump.** A bump is for a node that emits something different
  for the same inputs. No node emits anything different: `ProcessOutput` still carries
  trees, and the trees a hit hands back are the trees the run produced. The entry's shape
  changes, which the decode failure covers for every type at once.
- **`debug <cache key>`** shows the key material, which is unchanged; `check` reads the
  graph, not the cache. `ObjectCollector` reads an entry's output values only.
- **`ProcessOutput` and every node.** Nodes build and return trees, as B-115 left them.

## Cost

One fold per stored entry — a hash per occurrence, which is what `applySpecs` already pays
for the same trees on the run that stored them — and one unfold per hit, which builds each
distinct node once. Every existing entry misses once.

## Acceptance

1. On the IceCubes packages tree the largest cache entry falls from about 15.5 MB to well
   under 1 MB, and the compact database from about 36 MB to a few MB.
2. The build's products are byte-identical before and after.
3. After a `reset`, which keeps the cache, a second build answers from the cache as it did
   before.

## Tests

- `SemelNodeKit` (`GraphSpecTableTests`): a shared subtree is one row; each row is filed
  under its subtree's `identity()`; one node listed in two orders is one row; trees round
  trip, including a port with no wires and a demand with no output port; an unfolded tree
  has the identity it was filed under; a missing row and a cycle fail to unfold; a row
  naming an unlinked type is reported; equal trees encode to the same bytes whatever order
  their dictionaries were built in; the table is a fraction of the trees it folds.
- `SemelCore` (`CacheTests`): an entry whose table names an unlinked type, at the root or
  deeper, is a miss; a table that does not unfold is a miss; a hit wires what its stored
  table demands — every wire from the node its tree describes, the shared node made once.

## As built (2026-09-27)

As designed. What the text above leaves open:

- **`GraphSpecTable`** is `Equatable` and `Codable`, with `Reference`, `Row`, `Port` and
  `Wire` nested in it, and a public memberwise initialiser beside `init(trees:)`: a decoder
  makes a table as it stands, and so do the tests that store an entry no fold of this
  Semel's trees could produce — one naming an unlinked type, one that does not unfold.
- **The fold throws what `identity()` throws**: `GraphSpecIdentityError.unknownTypeName` for
  a type this Semel does not link, `wireWithoutOutputPort` for a wire whose source names no
  port. A node's output that demands such a tree already fails in `applySpecs` before the
  save is reached, so the save's throw is never the first word.
- **A port with no wires is kept** as a port with no references: it asks `applySpecs` to
  remove every wire on that port, and dropping it would keep them.
- **`DictionaryOrderTests`** loses its entry for the walk of `inputWireSpecs.values` in
  `loadCachedOutputs`; the fold and unfold walk dictionaries sorted, and the check of rows
  asks one question of each.

Measured on the IceCubes packages tree (the copy B-115 was measured on), a cold build in a
fresh home and then, after a `reset` that keeps the cache, a second build:

| | before | after |
|---|---|---|
| largest cache entry (the project builder's) | 15,567,712 bytes | 179,136 bytes, 218 rows |
| second largest | 15,567,146 bytes | 178,570 bytes |
| the cache, 253–254 entries | 34.0 MB | 4.2 MB |
| the other entries together | 2.9 MB | 3.8 MB |
| compact database (`VACUUM INTO`) | 36.1 MB | 6.2 MB |
| cold build | 109 s | 95 s |
| second build after `reset` | 61 s, 157 of 180 from cache | 32 s, 157 of 180 from cache |

The five archives are byte-identical across the four builds. The cold build's time is
within the noise of the tools. The second build's halves, most likely because the project
builder's hits no longer decode 15 MB of JSON and walk a 20,000-node tree for its type
names — not profiled.

Residuals:

- **The applier does not walk the table.** A hit unfolds it into trees and `applySpecs`
  hashes each again to find the identities the table is keyed by. Walking it means handing
  `writeToOutputs` a table rather than a `ProcessOutput` on both hit paths and a
  find-or-create over rows; marked `TODO` in `loadCachedOutputs`.
- **Small entries grew by a third.** A reference is a 64-character identity, which costs
  more than the one- or two-node tree most entries demand. The total is still an eighth of
  what it was; a shorter reference — an index into the rows — would give up the property
  that a row's key is the graph's identity.
