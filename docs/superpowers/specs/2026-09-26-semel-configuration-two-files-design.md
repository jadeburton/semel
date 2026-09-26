# Configuration: the machine's half and the project's half (B-109)

**Status:** proposed
**Date:** 2026-09-26
**Builds on:** `2026-08-30-semel-configuration-design.md` (one namespace, wired files, prefix
selection) and `2026-09-25-semel-formula-preludes-design.md` (B-108).

## The problem

The configuration design is right about the things that are hard to get right. A tool's
settings arrive as a **wire value** selected out of a file by prefix, so the graph shape
records which file and which slice while the file's content stays a value: editing
`clang.linker.target` re-runs the linkers and leaves every compiler's identity and cache
alone. There are **no defaults**, so every value a tool used is written somewhere a reader
can open, and two machines cannot share a cache entry over different SDKs without either
knowing. And there is **no inheritance**, so no reader holds a resolution order in their
head.

What is wrong is not the mechanism but the file a person has to write. The C fixture's
config, for a three-line formula:

```
clang.preprocessor.toolDescriptor.name=clang
clang.preprocessor.toolDescriptor.version=Apple clang version 21.0.0 (clang-2100.1.1.101)
clang.preprocessor.toolDescriptor.platform=macOS
clang.preprocessor.toolDescriptor.architecture=arm64
clang.preprocessor.sdkPath=/Applications/Xcode.app/…/MacOSX.sdk
clang.preprocessor.target=arm64-apple-macos14.0
clang.preprocessor.cStandard=c17

clang.compiler.toolDescriptor.name=clang
… (the same four lines)
clang.compiler.target=arm64-apple-macos14.0
clang.compiler.cStandard=c17

clang.linker.toolDescriptor.name=clang
… (the same four lines)
clang.linker.sdkPath=/Applications/Xcode.app/…/MacOSX.sdk
clang.linker.target=arm64-apple-macos14.0
```

Twenty lines. Fifteen of them are **facts about the machine** — which clang is installed,
which SDK, where — repeated once per tool because nothing is inherited. Two are the
project's choice (`cStandard`), and three (`target`) are half and half. The machine facts
are why the file cannot be checked in, why the end-to-end fixtures carry a `.template` with
placeholders, and why the tutorial has its reader paste a block and then type seven lines by
hand. `FUTURE.md` names it: *no defaults is right; a person paying for it by hand is not.*

The spec killed inheritance because a resolution order is illegible. But repetition only
costs when a human writes it. The fix is in the authoring, not the model.

## Decisions

- **Two files, two owners.** A *machine file* holds every setting whose value is a fact about
  the machine the build runs on: the tool descriptors, the SDK's path and identity. It is
  generated, never edited, and ignored by version control. A *project file* holds the
  project's choices: the language standard, the deployment target, the optimisation level.
  It is written by hand once and checked in.
- **The machine file is written by one command from what the plugins declare.** Each plugin
  says which of its settings are machine facts and how to answer them; `tools` prints them
  and the writer writes them. No table in `prepare` decides per tool name.
- **The two are layered by the formula, explicitly.** A prelude func takes the settings as a
  node, and provides `settings(project:machine:)` that lays the project file over the
  machine file with `ConfigMerger`. The order is fixed and written in the prelude's text;
  the formula names both files. Nothing is found by convention.
- **Everything the 2026-08-30 design guarantees stays.** Settings are wire values; every key
  is spelled out under the node that reads it; a value has no default; a tool's slice is
  selected upstream by prefix; variants are files.

## The two files

```
semel.machine.config           written by `tools --write`; in .gitignore
    clang.compiler.toolDescriptor.name=clang
    clang.compiler.toolDescriptor.version=Apple clang version 21.0.0 (clang-2100.1.1.101)
    clang.compiler.toolDescriptor.platform=macOS
    clang.compiler.toolDescriptor.architecture=arm64
    clang.preprocessor.toolDescriptor.… (four lines)
    clang.preprocessor.sdkPath=/Applications/Xcode.app/…/MacOSX.sdk
    clang.linker.toolDescriptor.… (four lines)
    clang.linker.sdkPath=/Applications/Xcode.app/…/MacOSX.sdk

semel.config                   written once by hand; checked in
    clang.preprocessor.target=arm64-apple-macos14.0
    clang.preprocessor.cStandard=c17
    clang.compiler.target=arm64-apple-macos14.0
    clang.compiler.cStandard=c17
    clang.linker.target=arm64-apple-macos14.0
```

Both are ordinary files under the one flat namespace, both reach the graph as `StaticFile`s,
and a key may appear in either. Which file a key *belongs* in is a fact about the key, stated
by the plugin (below), and the writer puts a key it owns in the machine file and nothing else
there. A project file that names a machine key is not an error: the project file is laid over
the machine file, so a project can pin a toolchain on purpose, in the checkout, where the
pin is reviewable.

The project file still repeats `target` per tool. That is the design working — each node's
settings complete where they are written — and it is five lines rather than twenty. What
would remove it is not inheritance but a change to the key (see *Later*).

## What a plugin declares

`ToolNamespace` already carries `machineSettings: () -> [String: String]`, which `tools`
prints beside the tool descriptor; `SemelSwift` answers `sdk` and `sdkVersion` through it and
`SemelClang` answers nothing, so `prepare` decides clang's `sdkPath` from a `switch` on the
tool name. That table moves into the plugins:

```swift
public struct ToolNamespace {
    public let namespace: String
    public let toolName:  String
    /// Settings whose value is a fact about this machine, for a platform: the SDK's path,
    /// its identity. Written by `tools --write` and printed by `tools`; a project never
    /// types them. The platform is an input because the SDK is one per platform.
    public let machineSettings: (Platform) -> [String: String]
}
```

The tool descriptor's four keys are machine facts for every namespace and need no declaring.
A key a plugin does not name here is the project's, and `RequiredSettings.check()` already
reports the two kinds apart — "run `tools` for these" against "`=…`, your choice" — by the
`toolDescriptor.` prefix; it reads the declaration instead, so a missing `sdkPath` is
reported with the machine keys it belongs with.

`Platform` moves from `semel-swift` to `SemelNodeKit`: it is the one thing a machine setting
is a function of, and every plugin that has an SDK needs it.

## Writing the machine file

```
tools --write semel.machine.config [--platform macos]
```

The CLI asks the daemon what `tools` already answers — every registered namespace, its
installed tool and its machine settings for the platform — and writes the blocks for the
namespaces **the graph selects**: the prefixes of the `ConfigFilter` nodes below the file,
which exist after the first build attempt whether or not the file did. That is the loop the
missing-settings report already describes, made one step:

```
build hello --into out
  ❌ ClangCompiler #12 …
     Missing configuration. Add these to a semel.config in the input file system:
     clang.compiler.target=…
     clang.compiler.cStandard=…

     clang.compiler.toolDescriptor.name
     … Run 'tools --write semel.machine.config' for those.
tools --write semel.machine.config
  Wrote 3 namespaces: clang.compiler, clang.linker, clang.preprocessor
build hello --into out
```

A namespace nothing selects is not written: a file holding every installed tool's settings
would be flagged by the unused-key report in every project. Before any build has run, the
graph selects nothing and the command says so; `--all` writes every installed namespace for
the reader who wants a master file.

`semel-swift prepare` keeps writing configuration for a tree of packages, and writes it as
these two files: the machine half through the same writer, and the project half holding what
it derives from the manifests — the deployment target and the `target` triple — plus, for a
C target, a language standard as a **starting point, marked as a choice**:

```
// Written by semel-swift prepare. These are the project's choices; edit them.
clang.compiler.cStandard=gnu11      // prepare's starting point, not clang's default
```

Today prepare writes `cStandard=gnu11` beside the machine facts with nothing saying which
kind of line it is. In the project file, under a comment, it is a value in the checkout that
somebody chose, which is what "no defaults" asks for.

## The preludes

A prelude func takes its settings as a **node**, not a path, and each prelude provides the
two-file merge:

```
func settings(project, machine) = ConfigMerger(
  base:     [StaticFile(path: machine)],
  override: [StaticFile(path: project)]
)

func executable(sources, settings) = linked(sources: sources, settings: settings, dynamicLibrary: 'false')
…
func selected(settings, prefix) = ConfigFilter(prefix: prefix, input: [settings])
```

The formula:

```
include 'clang'

func settings() = clang.settings(project: <semel.config>, machine: <semel.machine.config>)

product "hello.dylib" = clang.dynamicLibrary(sources: <src>, settings: settings())
product "hello"       = clang.executable(sources: <src>, settings: settings())
```

Four lines where B-108 had three, and the line it adds is the one that names the inputs. It
is also what answers B-108's residual 4: a project that layers a local file over a shared one
— the `cpp` fixture's `ConfigMerger(base: <../clang.cfg>, override: <clang.cfg>)` — builds its
own settings node and passes it, with no prelude change. Settings as a node is the seam that
lets the simple case be short and the complex case be possible.

`ConfigMerger`'s `override` port tolerates an absent file, so a project with nothing to say
beyond the machine facts may name a project file it never writes; the machine file is the
`base`, and a base nobody wrote is reported by name.

### `Configuration(inherit:)` is renamed

In a design whose pillar is *no inheritance*, the port `Configuration` takes its wire values on
is called `inherit`. It means "start from these values and lay my properties over them" —
the same relation `ConfigMerger` calls `base` and `override`. It becomes `base`. The port name
is in every `Configuration` node's spec, so the rename changes the identity of every one and
of everything below it: a `Semel.version` bump, which is what a rename of a stored name costs
(B-29, B-44), and the converter's emitted text and both preludes change with it.

## The unused-key report has to look through a merger

`BuildEngine.unclaimedConfigKeys` finds the prefixes a config file is selected by through the
wires from the file's node to `ConfigFilter` nodes — direct wires only. A file wired into a
`ConfigMerger`, or into a `Configuration`, and only then into filters, has no `ConfigFilter`
consumer and is never reported on. That is already true of the `cpp` fixture; with every
prelude formula wiring a merger it would be true of every project. The report follows a
config file through `ConfigMerger` and `Configuration` to the filters that select from what
they produce, and a key neither file's selectors claim is reported against the file that
holds it.

## What stays as it is

- **No inheritance across tools.** `target` is written per tool in the project file.
- **No defaults.** A value prepare writes into the project file is a value in the checkout,
  marked as a choice.
- **Variants are files.** `settings: clang.settings(project: <release.config>, machine: …)`.
- **Per-target overrides** stay the accepted limitation the 2026-08-30 design records.

## Later, not here

- **`target` split into its parts.** `arm64-apple-macos14.0` is an architecture (the
  machine's, and already in `toolDescriptor.architecture`), a platform and a deployment
  version (the project's). A tool that took `platform` and `deploymentTarget` and composed
  the triple with its own architecture would let the project file say nothing about the
  machine at all — and a project checked out on an Intel Mac would build for it. A change to
  each tool's settings, worth its own item once the two files exist.
- **The project half written by prepare for a hand-written formula.** prepare writes a
  project file only for the trees it converts; a C project's is typed. Five lines, and the
  missing-settings report names each one.

## Acceptance

1. The `c`, `tutorial` and `HelloApp` fixtures build from a generated `semel.machine.config`
   and a checked-in `semel.config`; `clang.cfg.template` and `ClangConfigTemplate` are gone,
   the harness runs `tools --write` where it rendered the template.
2. `tools --write` writes exactly the namespaces the graph selects, says so, and refuses
   with a sentence when the graph selects nothing; `--all` writes every installed namespace.
3. `RequiredSettings` reports a missing machine key — `sdkPath` included — with the
   `tools --write` instruction, and a project key with `=…`.
4. `unclaimedConfigKeys` reports an unused key in a file that reaches its filters through a
   `ConfigMerger`; the `cpp` fixture is the case.
5. The tutorial's config section is: `tools --write`, then type the project file's five
   lines. The "paste this block" step is gone.
6. `Configuration`'s port is `base`; `Semel.version` is bumped; the converter's emitted
   formula, both preludes and `EmittedFormulaConfigurationTests` say `base`.
7. `semel-swift prepare` writes two files, and its C standard lands in the project file under
   a comment naming it a choice.

## Open questions

- **The machine file's name.** `semel.machine.config` beside `semel.config`, or
  `semel.config.machine`? The first sorts beside its sibling and reads as a config file; the
  second says whose half it is. Either way one name, in `.gitignore`, used by prepare, the
  tutorial and the fixtures.
- **`--platform` on `tools --write`.** A machine setting is one per platform, and a project
  that builds for the simulator and for macOS wants both blocks in one machine file.
  Whether the writer takes one platform, several, or writes every SDK the machine has for
  the namespaces selected, is a question for the first project that needs two.

## As built (2026-09-27)

Both open questions closed the simple way: the file is `semel.machine.config`, and
`tools --write` takes one `--platform` (macOS unless said). What differs from the text
above, and what it did not foresee:

- **`ToolNamespace` declares its machine keys as well as answering them** —
  `machineSettingKeys: Set<String>` beside `machineSettings: (Platform) -> [String: String]`
  — because `RequiredSettings.check()` runs on a machine that may lack the SDK, where the
  closure answers nothing and the report would have filed `sdkPath` under the project's
  keys. Two headings, one per owner: the project's keys under *add these to semel.config,
  with your values*, the machine's under *run `tools --write`*.
- **The renderer moved to `SemelProtocol`** (`ToolNamespaceRenderer.machineFile`), the one
  package both writers depend on; a file pins each namespace to the newest installed tool
  where the listing shows every version. `prepare` builds the same records the daemon
  builds for `tools`, in its own code — the type that could share it would have to know
  both the registry and the protocol.
- **`tools <prefix> --all --write`** writes every installed namespace under the prefix. The
  harness uses it — `tools clang --all --write` — where it rendered the template, since no
  graph exists in a run before its first build; the user's loop, build → write → build, is
  `AutostartTests.test_theMissingSettingsLoopIsBuildWriteBuild`.
- **The unused-key report walks both ways**: down from a file through `ConfigMerger` and
  `Configuration` to the selectors, and up from each selector to the files, so the file
  behind a prelude's merger is both found and read through.
- **`prepare` rewrites the machine file every run** and keeps the project file and the
  formula, as before; a namespace with nothing of the project's to say — the package
  reader, xcstringstool — has no block in the project file.
- **The C fixtures' machine file is shared**, `../semel.machine.config` beside the three
  build folders, which keeps B-110's follow loop in the tutorial's first build; `HelloApp`
  and prepared trees have theirs beside the formula. `cpp`'s own file is `semel.config`.
- **Not done:** this repository's own `semel.config` still carries its machine facts
  (residual 1 in FUTURE.md's B-109).
