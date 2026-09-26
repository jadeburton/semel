# Your first node

Half an hour, in four parts: build a small C program with Semel, watch what is and is not
redone when things change, write a node type of your own, and use it in a build.

This is for someone who wants to work on Semel. If you only want your Swift project built,
the README's [clone to build](../../README.md#dependencies-and-clone-to-build) is two
commands. Words in *italics* are defined in the [glossary](../../AGENTS.md#glossary); they
are introduced here where they first do something.

Last walked through at commit `d5cc9f1`, and Parts 1 and 2 again when the prompt learned to
print a settle summary. The commits in between change documents, comments, tests and the
shape of the reference node's loop — not what anything prints.

## Part 1 — Build something

```sh
git clone <repo-url> && cd semel
swift build
```

A debug build, not `-c release`: two steps in Part 3 read the running commentary
`semelserv` prints, and that is compiled out of a release build. Plain `swift build` is
right for this one, because a first build plans from scratch; Part 3 swaps to
`scripts/build.sh` at the point where that stops being true, and says why.

You will want three terminals open, and the document says which one each step is in:

| Terminal | What runs in it |
|---|---|
| **server** | `semelserv`, started once and left alone. Parts 1 and 2 read nothing of what it prints; two steps in Part 3 do. |
| **prompt** | `semel`. Unlabelled fences are either what you type here or what something printed; the sentence before each says which. |
| **shell** | an ordinary shell in the checkout; `sh` fences are typed here unless the step names another terminal. |

The prompt is not a shell and the shell is not the prompt: `semel` knows `push` and `build`
and nothing else, so copying a file or running the program you just built happens in the
third terminal. You can leave the prompt running the whole time; `quit` ends it.

Two executables matter. `semelserv` is the engine: it holds the graph and does the work.
`semel` is the prompt you type at. Day to day you never start the engine: `semel` starts
one when none is running and leaves it running (`semel stop` ends it). This tutorial reads
what the engine prints in Part 3, so here you start it yourself. In the **server**
terminal, start it and leave it running:

```sh
.build/debug/semelserv
```

```
Semel server 0.1.2
Graph:  /Users/you/Library/Application Support/semel/graph.sqlite
Socket: /Users/you/Library/Application Support/semel/semelserv.sock
```

In the **shell** terminal, make a copy of one of the test fixtures to work in. Everything
you build lives there, so nothing you do in Parts 1 and 2 touches the checkout:

```sh
mkdir ~/semel-playground
cp -R EndToEnd/Fixtures/c ~/semel-playground/hello
```

In the **prompt** terminal, start the prompt:

```sh
.build/debug/semel
```

It prints its version and the graph it is talking to, and then waits. There is no `>`: you
type a command and press return. Tell it where your files are — `semel` expands the `~`
itself, and the setting lasts as long as the session, so you type it once:

```
base ~/semel-playground
```

```
Base directory set to /Users/you/semel-playground
```

### The config

Semel has no defaults. Every tool a build runs is named in configuration, down to its
version, because the version is part of what makes a cached result reusable. The
configuration is two files with two owners. The *project's* file holds what you decide —
the target and the C standard, spelled out per node, because there is no inheritance. It
came with the copy, as a project's would with its checkout: open
`~/semel-playground/hello/semel.config`. Under a comment, five lines:

```
clang.preprocessor.target=arm64-apple-macos14.0
clang.preprocessor.cStandard=c17
clang.compiler.target=arm64-apple-macos14.0
clang.compiler.cStandard=c17
clang.linker.target=arm64-apple-macos14.0
```

That is `arm64-apple-macos14.0` on Apple silicon, as shown; on an Intel Mac change it to
`x86_64-apple-macos14.0`. Everything after the first `=` is the value, quotes included —
so no quotes. This file is yours, and it is what you would check in.

The *machine's* file holds what is a fact about this Mac — which clang, which SDK — and
you do not write it. Ask for the build first:

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla
Push file: hello/semel.config
Push file: hello/src/common.h
Push file: hello/src/hello.c
Push file: hello/src/hello.h
Push file: hello/src/hello2.c
Push file: hello/src/main.c
❌ 19 nodes scheduled, 19 computed, 0 from cache, 25 errors
Settled.
25 errors across 9 nodes:

❌ ClangCompiler ×3 (#23, #27, #29)
   · errorLog, infoLog, output:
     Missing machine settings. Run 'tools --write semel.machine.config': it writes the tool descriptors and SDK facts of the tools installed here, for every namespace this graph reads, these among them:
     clang.compiler.toolDescriptor.architecture
     clang.compiler.toolDescriptor.name
     clang.compiler.toolDescriptor.platform
     clang.compiler.toolDescriptor.version
…
❌ StaticFile #17 'input:/semel.machine.config'
   · semel.machine.config has not been pushed
   · and 1 node downstream carries it
```

It failed, and it says why: the formula names `<../semel.machine.config>` beside `hello/`,
nothing is there, and every tool below it lacks the settings that file would hold — and
each names the command that writes them. Run it:

```
tools --write semel.machine.config
```

```
Wrote 3 namespaces to /Users/you/semel-playground/semel.machine.config: clang.compiler, clang.linker, clang.preprocessor
```

Three, not the eight this server knows: `tools --write` writes the namespaces the graph
you just built actually selects, so nothing in the file goes unread. The path is relative
to where you ran `semel`, which is beside `hello/`, where the formula looks. Open it if you
like — the clang version string, the SDK path, once per tool — but do not edit it, and do
not commit it: it is this machine's, and the next machine writes its own.

### The build

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/semel.config [no change]
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
Settled.
hello/hello.fmla needs ../semel.machine.config
Push file: semel.machine.config
✅ 24 nodes scheduled, 24 computed, 0 from cache, 0 errors
   appeared: output:/hello/config.txt
   appeared: output:/hello/hello
   appeared: output:/hello/hello.dylib
Settled.
No errors.
Exported 3 files into /Users/you/semel-playground/out
```

Two settles. `build` pushed `hello/` again — nothing in it changed — and the formula's
`<../semel.machine.config>` is outside it, so the first settle still lacked it. This time
the file exists, so the engine's report named the one source the formula needs that nobody
has pushed, and `build` pushed it, saying which formula asked, and waited again. The second
settle is the build. That is the whole rule: *build follows the formula's inputs within your
tree*. It never pushes anything the formula did not name, and never anything outside the
base directory, which is where you ran `semel` unless `base` says otherwise. `--no-follow`
turns it off.

The line with the tick is the *settle summary*: one line per settle, saying what the engine
did. Every number counts nodes, each one once, however many times the engine came back to
it. Nothing came from the cache, because there was no cache to come from — this graph had
never been built. Part 2 is about that column. The counts are from one walk-through and
yours will differ a little; the two right-hand numbers usually add up to the first, and
fall short of it when a node is woken, found to be waiting on something, and never gets as
far as producing anything before the graph settles.

The indented lines under it are the *artifact diff*: what this settle did to the products,
as the difference between this settle and the last. Three verbs and no others — `appeared`,
`changed`, `disappeared`. A product that failed is not among them; that is what the error
report is for, and saying it twice in two vocabularies is what these lines were designed to
avoid. Nothing is said about the steps in between: a product republished with the bytes it
already had says nothing at all, which is what the next section is about.

`--into` expands the `~` the same way `base` does, and the products land beside your
sources rather than in the checkout. In the **shell** terminal:

```sh
~/semel-playground/out/hello
```

```
Hello, World 1!
```

`push` copied your files into Semel's own input file system — the engine never reads your
disk during a build, only what was pushed. `build` is `push`, wait until the graph settles,
report errors, and copy the products out. `semel.machine.config` needs its own `push`
because `build` pushes the folder you name and that file is not in it — which is what you
watched: the report named the file itself, `semel.machine.config has not been pushed`,
under the missing-setting errors from the tools that then had nothing to read.

### What you just ran

Open `~/semel-playground/hello/hello.fmla`. It is a *formula*: it says what the products
are, as expressions, and nothing about order or commands.

```
include 'clang'

func settings() = clang.settings(project: <semel.config>, machine: <../semel.machine.config>)

product "hello" = clang.executable(sources: <src>, settings: settings())
```

A *product* is an expression whose value is published. Everything else is intermediate and
stays inside. A formula names no toolchain until it includes one: `include 'clang'` brings
the funcs the Clang plugin provides, and `clang.executable` is one of them — a folder of
sources and the settings in, a program out. `clang.settings` is another: your file laid
over the machine's, which is the only place the formula says which is which. A `func` is
only a way not to write the same expression twice, and what `clang.executable` stands for
is written in this same language. Its first step, for one source file:

```
func preprocessed(file, settings) = ClangPreprocessor(
  configuration: [selected(settings: settings, prefix: 'clang.preprocessor')],
  input: [file: StaticFile(path: file)]
)
```

`ClangPreprocessor(...)` and `StaticFile(...)` are *nodes*. The names before the colons —
`configuration`, `input` — are the node's input *ports*, and each `name: expression` inside
the brackets is a *wire*: a named connection carrying a value from one node's output to
another's input. `executable` makes one compile chain per file in `src`:

```
 src/hello.c  ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┐
 src/hello2.c ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┼─ ClangLinker ─ product "hello"
 src/main.c   ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┘
 semel.config ────────┐
 semel.machine.config ┴ ConfigMerger ─ ConfigFilter('clang.compiler') ─ … into every compiler
```

The whole prelude is twenty lines, in
[`ClangPrelude.swift`](../../SemelClang/Sources/SemelClang/ClangPrelude.swift). A formula
that needs something it does not do writes those expressions itself, and gets the same
nodes.

The graph is not rebuilt from the formula each time. It lives in a database, and nodes
react when a wire's value changes. Look at what it published:

```
ls -o hello
```

```
-rw-r--r--      1215  config.txt
-rwxr-xr-x     33504  hello
-rw-r--r--     33440  hello.dylib
```

## Part 2 — Watch it not work

The point of Semel is the work it does not do. Four experiments, each built at the
**prompt**, with any edit made in the **shell** terminal first. Everything you need is in
the settle summary, and three of its four numbers are the experiment:

- **scheduled** — how many nodes a change woke. This is the cascade: which nodes could
  have been affected.
- **computed** — how many of those actually ran their tool.
- **from cache** — how many were woken, looked up their inputs, and did not run because an
  earlier build had already produced that exact answer.

Being **rescheduled** and being **recomputed** are different things, and most of Semel's
speed is the gap between them. The mark on the line is not about that gap — it says only
whether the settle left anything broken, ✅ for no and ❌ for yes.

The counts below are from one walk-through and yours will differ. What matters is how they
move between the experiments.

**1. Build again.**

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/semel.config [no change]
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
Settled.
No errors.
Exported 3 files into /Users/you/semel-playground/out
```

Every push says `[no change]`, no artifact line appears, and there is no summary either.
A settle that woke nothing says nothing: no wire changed, so no node was scheduled, so
there is nothing to report. (`Exported 3 files` is the export copying what is already
there; it is not a rebuild.)

**2. Change one file.** In the **shell** terminal, edit
`~/semel-playground/hello/src/hello2.c` — change the text it prints — then build at the
**prompt**.

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/semel.config [no change]
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c
Push file: hello/src/main.c [no change]
✅ 9 nodes scheduled, 8 computed, 1 from cache, 0 errors
   changed: output:/hello/hello
   changed: output:/hello/hello.dylib
Settled.
No errors.
```

One file pushed without `[no change]`; two of the three products republished, and
`config.txt` not. Nine nodes woken out of the thirty-eight in this graph, and eight of them
ran: the project finder and the include finder, then one preprocessor and one compiler —
`hello.c` and `main.c` were not touched, so two of each stayed asleep — then both linkers,
because both products take that object, then the two output files. The ninth is the node
that reads `hello.fmla`, which did not change: one hit, in a settle that otherwise did
everything.

**3. Put it back.** Undo the edit and build. The prompt prints exactly what it printed
last time, line for line — the same file pushed, the same two products republished — with
one line different:

```
✅ 9 nodes scheduled, 4 computed, 5 from cache, 0 errors
```

The same nine nodes were woken. Four ran; five did not, and those five are the preprocessor,
the compiler, both linkers and the formula reader — the entire chain that had just been
rebuilt, cache hits from end to end. A *cache entry* is keyed on the node's type, its
properties and the name and content of everything wired to it; time appears nowhere, so a
file restored to what it was asks the same question as before and gets the stored answer.
`scheduled` did not move and `computed` halved: that gap is the whole idea.

**4. Change a setting only the linker reads.** Add a line to
`~/semel-playground/hello/semel.config`:

```
clang.linker.exampleSettingNobodyReads=1
```

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/semel.config
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
✅ 18 nodes scheduled, 11 computed, 7 from cache, 0 errors
Settled.
No errors.
```

Not one C file changed, and both programs were relinked — the linkers' settings really did
change, even if the linker reads no such key, and the same bytes came out, which is why no
`changed:` line follows. What did not happen is the interesting part. Eighteen nodes woken,
against nine for a one-character edit to a source file: the settings feed every tool in the
build, so touching them wakes nearly the whole graph. Seven of those were answered from the
cache, and those seven are all six preprocessors and compilers plus the formula reader.

Each of the six reads its settings through a `ConfigFilter` that passes on only
`clang.compiler.*` or `clang.preprocessor.*`, so what reached them was byte-identical and
their keys did not move — woken, and not one of them ran. Only the linkers, whose selector
really did see a different file, had work to do. Nothing complains about the new key
either: an unused key is only reported when it falls under no selected prefix at all, and
`clang.linker` is selected. The header comment of
[`ConfigFilter.swift`](../../SemelCore/Sources/SemelCore/Nodes/ConfigFilter.swift) tells
this story in full, and the whole file is seventy-five lines — read it now; it is the shape
of the node you are about to write.

`errors` shows what is wrong when a build fails; after a good build it says `No errors.`
`debug` dumps the whole graph — thirty-eight nodes here, two thousand lines. It is a lot,
and worth seeing once.

## Part 3 — Write a node

`MyLineCounter`: whatever files are wired to it, it outputs one `name: count` line per
wire. No tool, no configuration — everything a node must have, and nothing else.

This is the part that does touch the checkout, and it has to: node types are compiled into
`semelserv`, so your node has to live in a package the server links. "Cleaning up" at the
end puts the checkout back.

A finished copy is in
[`SemelExamples/Sources/SemelExamples/LineCounter.swift`](../../SemelExamples/Sources/SemelExamples/LineCounter.swift).
Write your own beside it as `MyLineCounter.swift`; two types in one module cannot share a
name, and the name is yours to choose anyway. Files here open with a header comment saying
what the file is for — `LineCounter.swift`'s is the shape; the listing below starts after it.

```swift
import SemelDatabaseModels
import SemelNodeKit

public struct MyLineCounter: Node {
    public static let kind: UInt = 37
```

`kind` is how a node stored in the database finds its Swift type again. It is a number you
assign by hand: the next one above the highest in the repository
([how to find it](../../AGENTS.md#choosing-a-kind)). If `37` is taken by the time you read
this, take the next.

```swift
    static let inputPort = "input"
    static let outputPort = "output"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(inputPort)],
        outputPorts: [outputPort]
    )
```

`thisNode` is the database row; `thisNode.properties` holds whatever plain values the
formula passed (`dynamicLibrary: 'true'` in Part 1). The descriptor declares the ports. One
input port can hold any number of named wires.

```swift
    public func process(input: ProcessInput) throws -> ProcessOutput {
        let wires = input.inputValues[Self.inputPort] ?? [:]

        var lines: [String] = []
        for (name, value) in wires.sorted(by: { $0.key < $1.key }) {
            let text = try value.expectValue().resolveAsString()
            lines.append("\(name): \(Self.lineCount(of: text))")
        }

        return .init(outputValues: [Self.outputPort: .value(try lines.joined(separator: "\n").intern())],
                     inputWireSpecs: [:])
    }

    /// Newline-terminated lines, plus a last line that has no newline.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? newlines : newlines + 1
    }
}
```

Four things to notice.

- A wire's value is not the file. It is a hash; `resolveAsString()` fetches the content
  from the object store, and `intern()` stores your output and hands back its hash. Values
  travel as hashes so that "did this change?" is always a cheap comparison.
- `expectValue()` throws when a wire is pending or in error, which fails this node.
  `ConfigFilter` skips such a wire instead; the comment above its wire loop says why. For a
  count, a silent omission would be a wrong answer that looks right.
- Sorted, because a dictionary's order changes from one process to the next and your
  output is compared byte for byte. Non-deterministic output is a cache that never hits.
- `process` is a pure function of its input. It may not read the disk, the clock or the
  environment. A node that must — a compiler reads an SDK — says so through
  `cacheKeyMaterial`; see [`Node.swift`](../../SemelNodeKit/Sources/SemelNodeKit/Node.swift).

Register it, in `SemelExamples.swift`:

```swift
        try TypeRegistry.register(types: [
            LineCounter.self,
            MyLineCounter.self,
        ])
```

Node types are linked into the server — there is no loading at run time — so rebuild and
restart it: stop `semelserv` in the **server** terminal, `scripts/build.sh` in the
**shell**, then start `semelserv` again. The prompt can stay open. The graph is in the
database; it is still there when the server comes back, and nothing is rescheduled by the
restart.

Build with `scripts/build.sh` rather than `swift build`, which is why: a plain `swift build`
from the repository root does not notice a file you have just **added** to a package it
depends on by path. Its cached build plan lists the files that were there before, and the
compiler says `cannot find 'MyLineCounter' in scope` about the file you are looking at. The
script is `swift build --disable-build-manifest-caching`, which plans afresh every time.

## Part 4 — Use it

In the **shell** terminal, add one line to `~/semel-playground/hello/hello.fmla`:

```
product "lines.txt" = MyLineCounter(input: [{f: <src/*.c>} "%%f.0%%.c": StaticFile(path: f)])
```

`{f: <src/*.c>}` makes one wire per matching file. The string before the colon is the wire's
name, and `%%f.0%%` is what the `*` matched — `hello`, `hello2`, `main` — and the `.c`
after it is literal, so the wires are named `hello.c`, `hello2.c`, `main.c`. Write `%%f%%`
instead and the wire is named for the whole mounted path —
`input:/hello/src/hello.c` — and a path in the name is a path in the product. The formula
chooses the names; your node only ever sees what it is handed.

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
Settled.
No errors.
Exported 4 files into /Users/you/semel-playground/out
```

The formula changed and not one C file was recompiled: only the new product was published.

In the **shell** terminal:

```sh
cat ~/semel-playground/out/lines.txt
```

```
hello.c: 14
hello2.c: 12
main.c: 16
```

Now the experiments from Part 2, on your own node:

- Add a line to `hello2.c`, build: `hello2.c: 13`, and the other two lines are the same
  bytes. The server shows `processWithCatch(input:): MyLineCounter, nodeID 37`, and that
  file's compile chain beside it; nothing else.
- Undo it, build: the clang chain around your node hits cache, and your node does not —
  `processWithCatch(input:): MyLineCounter, nodeID 37` again. Nothing is wrong. The engine
  only stores a cache entry for work that took more than fifteen milliseconds
  (`saveCacheForAllInputsAndOutputs` in
  [`Cache.swift`](../../SemelCore/Sources/SemelCore/Cache.swift)), and counting three files
  is far under it: looking the answer up would cost more than working it out. You wrote no
  caching code, and that is exactly why the engine gets to make this choice for you.
- Add `src/extra.c` with one function in it, build: a fourth line appears at the top of
  `lines.txt` and the formula did not change. The glob is a node too — a `Folder` — and its
  manifest changed. Your node is not the same node afterwards: a different set of wires is
  a different *spec*, so the engine matched nothing and made a new `MyLineCounter`, which
  `debug` will show you with four wires and a new number.

## Cleaning up

Keep the node if you like it. If you want the checkout back as it was, the order matters,
because your graph database holds a `MyLineCounter` node and a server built without that
type cannot read it.

First, in the **shell** terminal, take the product out of the formula: delete the
`lines.txt` line from `~/semel-playground/hello/hello.fmla`. Then, at the **prompt**:

```
build hello --into ~/semel-playground/out
```

```
Push file: hello/hello.fmla
Settled.
No errors.
Exported 3 files into /Users/you/semel-playground/out
```

Three files, not four: the node is unwired and gone from the graph. Only then, in the
**shell** terminal, remove it from the code and rebuild:

```sh
rm SemelExamples/Sources/SemelExamples/MyLineCounter.swift
git checkout -- SemelExamples/Sources/SemelExamples/SemelExamples.swift
scripts/build.sh
```

The stale build plan is the Part 3 snag again, from the other side: run a plain `swift
build` here and it stops with `missing inputs: …/MyLineCounter.swift`, naming the file you
meant to delete, while `semelserv` keeps the type it was linked with.

Restart `semelserv` in the **server** terminal. In the **shell**, `git status` is clean.

Do it the other way round — remove the type first — and the next build that wakes the node
says so:

```
❌ ProjectBuilder #3 'input:/hello/hello.fmla'
   · products, status: no type is registered for kind 37
```

The number after `#` is the node's row in the graph, the same one `check` names it by;
yours depends on what the home held before, so it may differ.

The way out is the same step you skipped: delete the `lines.txt` line from the formula and
build again. That clears the error, though the server may keep printing a bare
`The operation couldn’t be completed. (SemelNodeKit.TypeRegistryError error 1.)` while a
stale row survives. `reset` clears that. It is not scoped to this tutorial — what you
pushed is kept, and everything built from it is discarded and rebuilt: every product and
intermediate of every project in this home, not only of `hello`. The cached builds are
kept, so that rebuild is a pass of cache lookups rather than a cold build. The graph it
discards is copied aside first, and the reply says where:

```
reset
```

```
Graph copied to /Users/you/Library/Application Support/semel/graph.sqlite.broken-2026-09-23T101500Z — yours to delete.
Rebuild started.
Run `check` before the next reset: it names the invariants a graph is breaking — the evidence a reset discards.
```

That copy is the only record of the graph the reset threw away, and nothing removes it for
you: delete it once you are sure you do not need it. `reset --cache` discards the cached builds as well, which is the
answer to a cached result you believe is wrong and costs a cold build of everything in the
home.

## Where next

Each of these is the smallest real example of something this tutorial left out.

| To learn | Read |
|---|---|
| A node that runs a tool: `ToolRunner`, tool discovery, a config namespace | [`StringCatalogCompiler.swift`](../../SemelApple/Sources/SemelApple/StringCatalogCompiler.swift) (85 lines) and [`SemelApple.swift`](../../SemelApple/Sources/SemelApple/SemelApple.swift) |
| A node whose output is a tree of files | [`AssetCatalogCompiler.swift`](../../SemelApple/Sources/SemelApple/AssetCatalogCompiler.swift) |
| A node that asks for more inputs while it runs (`inputWireSpecs`) | [`ClangIncludeFinder.swift`](../../SemelClang/Sources/SemelClang/ClangIncludeFinder.swift) |
| A node that emits formula text | [`SwiftFormulaConverter.swift`](../../SemelSwift/Sources/SemelSwift/SwiftFormulaConverter.swift) — 1,228 lines; read [`XcodeProjectConverter.swift`](../../SemelApple/Sources/SemelApple/XcodeProjectConverter.swift) first |
| What must never break, and what looks wrong but is deliberate | [`AGENTS.md`](../../AGENTS.md) |
| What needs doing | [`BACKLOG.md`](../../BACKLOG.md) |
