# Configuration: one namespace, wired files, prefix selection

**Status:** implemented
**Date:** 2026-08-30
**Replaces:** the `semel.config` model shipped in `1bdc601`…`8a9fd0e`, which works for Swift
and reaches SemelClang not at all. Tracked as B-42.

## What was wrong with the first attempt

Not the file format — `key=value` per line is right, and stays. Three things underneath it.

**Settings became node identity.** `SwiftFormulaConverter` resolved the config and wrote the
values into the formula as `Configuration(...)` **properties**. A searchKey renders the whole
upstream shape, so editing `swift.sdkVersion` did not rebuild a node; it made a *different*
node, deleted the old one, and orphaned its cache. Toggling a setting never hit cache.

**There was no seam for Clang.** Swift has a converter to merge settings into. A `.fmla`
project has none — the author writes `Configuration(std: 'c++17')` by hand — so the
`settingNamespace` and `acceptedSettings` declared on the three Clang tools are inert code.
Every bridge attempted invented machinery: a path property to anchor an ancestor walk, a
registry mapping tool names to accepted keys, a new node type. That accretion was the signal
that the model was unsettled, not that the bridge was short a part.

**Filtering was in the wrong place, and only just.** A key one tool ignored still landed in
its properties, so an ignored setting changed its identity. Namespacing plus per-tool
`acceptedSettings` fixed the symptom, but the mechanism — a hand-kept list per type, checked
by a converter — has no counterpart on the Clang side and drifts from what the tool reads.

## What this design keeps and kills

**Kept:** `key=value` per line, one setting per line, `#` comments. Dotted keys. The file
lives in the input file system, so a change to it is an ordinary wire value change.

**Killed: inheritance, both dimensions.**

- *Across files.* No ancestor walk, no merge by depth, no nearest-wins. A configuration is one
  file. Copying a file and changing three lines is a perfectly good composition mechanism, and
  it is legible in a way a resolution order never is.
- *Across tools.* No `swift.sdkVersion` acting as a default that `swift.compiler.sdkVersion`
  overrides. Every key is written under exactly the node that reads it, spelled out in full.

`sdkVersion` therefore appears twice in a typical file, once for the compiler and once for the
linker. That duplication is the design working, not a wart to fix later: each node's settings
are complete where they are written, and no reader has to hold a merge order in their head.

**Cost, stated deliberately:** per-target overrides go too. "Everything is `-O` except this one
library" would need `swift.compiler.MyLib.optimisationLevel` beating
`swift.compiler.optimisationLevel` — most-specific-wins, which is inheritance in a hat. This is
a real limitation and a project reaches for it eventually. Accepted for now, knowingly.

## The namespace

One flat, global namespace, designed so that every key any node could ever read can coexist in
a single master config without collision.

    <domain>.<node>.<key>

    swift.compiler.sdkVersion             = 26.5
    swift.compiler.optimisationLevel      = speed
    swift.compiler.toolDescriptor.version = Apple Swift version 6.3.3 (…)
    swift.linker.sdkVersion               = 26.5
    clang.preprocessor.sdkPath            = /…/MacOSX.sdk
    clang.compiler.std                    = c++17
    clang.linker.target                   = arm64-apple-macos14.0
    semel.cache.entryLimit                = 20000

`<domain>` is who the setting is for, not which toolchain: `swift`, `clang`, and `semel` for
engine settings, so the file can hold everything rather than only toolchain settings.

`<node>` is **derived from the node type name**: drop a trailing `Tool`, then the first word
is the domain and the remainder, lower-camelled, is the node segment. `SwiftCompilerTool` gives
`swift.compiler`; `ClangPreprocessorTool` gives `clang.preprocessor`; `SwiftPackageReaderTool`
gives `swift.packageReader`.

Two consequences of deriving:

- `IncludeFinder` derives to `includeFinder`, at the root beside `swift` and `clang`, because
  its name does not say which toolchain it belongs to. Rename it `ClangIncludeFinder`. This
  serves B-44 anyway.
- **A type rename becomes a breaking change to every config file in the wild.** B-44 proposes
  renaming types, and three renames happened this month. So derivation is the *default*, and a
  type may pin its namespace explicitly with one line. Pinning is the escape hatch that lets a
  type be renamed after its namespace is public.

`<key>` may itself be dotted (`toolDescriptor.version`). No parsing is needed to tell key from
namespace — see below — so depth costs nothing.

## Selection: identity carries the selector

A node's configuration arrives as a **wire value**, never as a property. What is in the graph
shape is *which file, and which slice of it* — not what the file currently says.

    identity = which file, and which prefix is taken from it
    value    = what those keys currently say

Output ports are static per type (`NodeFunctionDescriptor.outputPorts: [String]`), so "one wire
per config line" cannot be one node with N ports. It does not need to be: node identity carries
the selector, the same way `StaticFile(path:)` already does.

    ConfigSubset(prefix: 'swift.compiler',
                 input: ['config': StaticFile(path: 'input:/semel.config').output]).output

One ordinary `output` port. The node strips its prefix and emits the remainder as
`key=value` lines — exactly the shape every tool's `init(properties:)` already reads, so no
tool changes. Two nodes with different prefixes are different nodes; ten thousand compilers
with the *same* prefix share one node through searchKey dedup.

Selection is prefix-strip, not parse. `swift.compiler.toolDescriptor.version` with prefix
`swift.compiler.` yields `toolDescriptor.version`, and nothing has to know where the namespace
ended and the key began.

### What this does to the 10,000-node problem

A cache key aggregates every input port's wire *values* (`Cache.swift:38`), which is why
filtering cannot live inside the tool: by the time unfiltered text is on the wire, the node has
already been rescheduled and its key already changed. Change `clang.linker.target` with the
whole file on every tool's wire and all ten thousand compilers get a new key, miss cache, and
recompile.

Selection upstream does not stop the cascade, and it is worth being exact about that.
Writing the config file marks the entire subgraph below it pending before the selector
reprocesses (`NodeSupport.writeToOutputPort`), so the selector's own write is `pending → value`
— a change by the engine's test — and everything downstream is rescheduled whether or not the
slice it selected actually moved.

What the selector holds still is **identity**. The prefix is in the graph shape and the values
are not, so after the edit the ten thousand compilers are the same ten thousand nodes with the
same cache keys. They wake, look themselves up, and find their previous result.

So the mitigation is: 10,000 reschedules and 10,000 cache lookups remain, and 10,000 recompiles
do not. Stopping the reschedule as well would need the engine to compare a node's new output
against its pre-pending value rather than against `pending`, which is a change to the engine,
not to this design.

### It dissolves `acceptedSettings`

The prefix in the graph *is* the accepted set: per node, visible in the shape, nothing to keep
in sync with what the tool reads. `ToolSchema`, the per-type `acceptedSettings` tables, and the
`suppliedByProject` diagnostics list all go.

## Variants are files, not namespace segments

Debug and release side by side is two complete files, `debug.config` and `release.config`,
wired into different `ConfigSubset` nodes. The variant is *which file a node is wired to*,
which keeps the namespace about what a setting is rather than which build it belongs to — and
it is why configuration values must not be identity: two variants are two nodes because they
name two files, not because their contents differ.

## Reporting keys nobody claimed

Killing the converter's whole-file view loses the current typo report, and a selector node
cannot replace it: it only knows what it was asked to select. But the graph records the answer.

For a given config `StaticFile`, follow the wires from its output port to `ConfigSubset` nodes
and collect their `prefix` properties. Any key in the file matched by no prefix was claimed by
nobody. This catches more than the old check did: both `swift.compiler.sdkVerison` (bad key)
and `swift.compier.sdkVersion` (bad prefix), where a per-tool accepted-set only ever saw the
first.

Timing: the set of selectors is complete only once the graph has settled, so this belongs on
the engine's idle hook (`BuildEngine.swift:139`), not at parse time.

## Migration

- **Swift.** `SwiftFormulaConverter` stops resolving configuration. It emits `ConfigSubset`
  nodes wired to the config file, and wires their output into each tool's `configuration` port
  alongside the manifest-derived literals it still writes (`moduleName`, `outputName`). The
  ancestor-walk expectations (`SemelConfig.expectations(forFolder:)`) go.
- **Clang.** A `.fmla` author writes the `ConfigSubset` node themselves. This is the first time
  Clang has any route to configuration.
- **Code removed.** `ConfigSettings` (merge-by-depth, two-dimension resolution, rejections),
  `SemelConfig.expectations`, `ToolSchema`, `settingNamespace`/`acceptedSettings` on all five
  tool types, `manifestSuppliedSettings`.
- **Code added.** The `ConfigSubset` node type; namespace derivation with an override;
  unclaimed-key reporting on idle.
- **`Configuration` survives unchanged.** It still carries formula literals — what a target
  *is* — and its `inherit` port still merges wired text, which is how a `ConfigSubset` output
  and manifest literals combine in one value for the tool.

## There are no default values

Settled, and it decides what a missing configuration means.

A setting that falls back to a literal in Swift source is worse than one read from the
machine. `xcrun` at least reports what is installed; a hardcoded
`"Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"` is a claim baked into
the binary, so **upgrading Semel silently changes what a previous build meant**. A build
system whose outputs move when the tool that built it is upgraded has given up the property it
exists for.

So: no defaults anywhere. A tool that needs `toolDescriptor.version` and is not given one
fails, naming what is missing and where to put it. A missing config file is therefore not an
empty configuration — it is a build that cannot start.

This applies to the Swift package converter too. A `Package.swift` does not state a toolchain
or an SDK, so a Swift package alone is not enough to build reproducibly: a config file has to
exist in the input file system supplying what the manifest cannot. That is a real ergonomic
cost — no project builds out of the box without one — and it is the price of the guarantee.

Concretely this removes: `?? "swiftc"`, `?? "Apple Swift version 6.3.3 (…)"`, `?? "macOS"`,
`?? "arm64"` (`SwiftCompilerTool.swift:29`, `SwiftLinkerTool.swift:24`),
`?? "arm64-apple-macos14.0"` (`ClangLinkerTool.swift:143`), and the `?? "Module"` /
`?? "output"` fallbacks for values the manifest is supposed to supply. It closes B-42's two
blocked TODOs.

Sequencing matters: defaults cannot be removed before there is a working way to supply the
values, so this lands after the selector, not with it.

## Boundary this establishes

A literal in formula text says what a thing **is**: `moduleName: 'Lib'`, from the package
manifest — identity, and correctly part of the searchKey. A config file says what environment
it is built **in**: never identity, always a wire value. That replaces a hand-kept list of
owned keys with a rule about where a value came from.

## Not settled

- What the node is called. `ConfigSubset` is a placeholder; B-44 already notes that
  `Configuration`, `ConfigSettings`, `ToolSchema`, `semel.config` and `NodeFunctionDescriptor`
  are five words circling one area, and this adds a sixth. Name it with that item, not before.
- Whether the prefix includes its trailing dot in the property (`swift.compiler` vs
  `swift.compiler.`), and whether an exact key with no remainder is legal.
- Whether `semel.*` engine settings are read through the same node type or a different path,
  since the engine is not a node. Out of scope here; nothing depends on it yet.
