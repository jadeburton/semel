# Your first node

Half an hour, in four parts: build a small C program with Semel, watch what is and is not
redone when things change, write a node type of your own, and use it in a build.

This is for someone who wants to work on Semel. If you only want your Swift project built,
the README's [clone to build](../../README.md#dependencies-and-clone-to-build) is two
commands. Words in *italics* are defined in the [glossary](../../AGENTS.md#glossary); they
are introduced here where they first do something.

Last walked through at commit `d5cc9f1`.

## Part 1 — Build something

```sh
git clone <repo-url> && cd semel
swift build
```

A debug build, not `-c release`: Part 2 reads the running commentary `semelserv` prints,
and that is compiled out of a release build.

You will want three terminals open, and the document says which one each step is in:

| Terminal | What runs in it |
|---|---|
| **server** | `semelserv`, started once and left alone. Part 2 reads what it prints. |
| **prompt** | `semel`. Everything in an unlabelled fence is typed here. |
| **shell** | an ordinary shell, in the checkout. Everything fenced as `sh` is typed here. |

The prompt is not a shell and the shell is not the prompt: `semel` knows `push` and `build`
and nothing else, so copying a file or running the program you just built happens in the
third terminal. You can leave the prompt running the whole time; `quit` ends it.

Two executables matter. `semelserv` is the engine: it holds the graph and does the work.
`semel` is the prompt you type at. In the **server** terminal, start it and leave it
running:

```sh
.build/debug/semelserv
```

```
Semel server 0.1.1
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

Semel has no defaults. Every tool a build runs is named in a config file, down to its
version, because the version is part of what makes a cached result reusable. That makes the
file the most tedious part of a first build, so do not write it — ask:

```
tools
```

`tools` prints a block for every namespace this server knows, `apple.*` and `swift.*`
included. The three you want are these:

```
clang.compiler.toolDescriptor.name=clang
clang.compiler.toolDescriptor.version=Apple clang version 21.0.0 (clang-2100.1.1.101)
clang.compiler.toolDescriptor.platform=macOS
clang.compiler.toolDescriptor.architecture=arm64

clang.linker.toolDescriptor.name=clang
clang.linker.toolDescriptor.version=Apple clang version 21.0.0 (clang-2100.1.1.101)
clang.linker.toolDescriptor.platform=macOS
clang.linker.toolDescriptor.architecture=arm64

clang.preprocessor.toolDescriptor.name=clang
clang.preprocessor.toolDescriptor.version=Apple clang version 21.0.0 (clang-2100.1.1.101)
clang.preprocessor.toolDescriptor.platform=macOS
clang.preprocessor.toolDescriptor.architecture=arm64
```

Save those three blocks as `~/semel-playground/clang.cfg` — beside `hello/`, not inside it;
the formula asks for `<../clang.cfg>`. What `tools` knows is which tools this machine has,
and nothing about what you want built with them. Three more facts are yours to decide —
the SDK, the target triple and the C standard — spelled out per node, because there is no
inheritance. Add them, with your own SDK path from `xcrun --sdk macosx --show-sdk-path`:

```
clang.preprocessor.sdkPath=/path/printed/by/xcrun
clang.preprocessor.target=arm64-apple-macos14.0
clang.preprocessor.cStandard=c17
clang.compiler.target=arm64-apple-macos14.0
clang.compiler.cStandard=c17
clang.linker.sdkPath=/path/printed/by/xcrun
clang.linker.target=arm64-apple-macos14.0
```

Everything after the first `=` is the value, quotes included — so no quotes.

### The build

```
push clang.cfg
build hello --into ~/semel-playground/out
```

```
Push file: clang.cfg
Push folder: hello
Push file: hello/hello.fmla
Push file: hello/src/common.h
Push file: hello/src/hello.c
Push file: hello/src/hello.h
Push file: hello/src/hello2.c
Push file: hello/src/main.c
output:/hello/config.txt: OK
output:/hello/hello.dylib: OK
output:/hello/hello: OK
Settled.
No errors.
Exported 3 files into /Users/you/semel-playground/out
```

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
report errors, and copy the products out. `clang.cfg` needs its own `push` because `build`
pushes the folder you name and that file is not in it.

### What you just ran

Open `~/semel-playground/hello/hello.fmla`. It is a *formula*: it says what the products
are, as expressions, and nothing about order or commands.

```
func preprocessor(path) = ClangPreprocessor(
  configuration: [config(prefix: 'clang.preprocessor')],
  input: [path: StaticFile(path: path)]
)
```

`ClangPreprocessor(...)` and `StaticFile(...)` are *nodes*. The names before the colons —
`configuration`, `input` — are the node's input *ports*, and each `name: expression` inside
the brackets is a *wire*: a named connection carrying a value from one node's output to
another's input. A `func` is only a way not to write the same expression twice.

```
product "hello" = make(dynamicLibrary: 'false', glob: <src/*.c>)
```

A *product* is an expression whose value is published. Everything else is intermediate and
stays inside. `make` expands the glob into one compile chain per file:

```
 src/hello.c  ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┐
 src/hello2.c ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┼─ ClangLinker ─ product "hello"
 src/main.c   ─ StaticFile ─ ClangPreprocessor ─ ClangCompiler ─┘
 clang.cfg ─ StaticFile ─ ConfigFilter('clang.compiler') ─ … into every compiler
```

The graph is not rebuilt from the formula each time. It lives in a database, and nodes
react when a wire's value changes. Look at what it published:

```
ls -o hello
```

```
-rw-r--r--      1126  config.txt
-rwxr-xr-x     33504  hello
-rw-r--r--     33440  hello.dylib
```

## Part 2 — Watch it not work

The point of Semel is the work it does not do. Four experiments. Each one edits a file in
the **shell** terminal, builds at the **prompt**, and is read in both the prompt and the
**server** terminal: the prompt tells you what was **pushed** and what was **published**,
and the server tells you what was **done**. Two of the server's lines are worth learning to
read:

- `processWithCatch(input:): ClangCompiler, nodeID 24` — that node ran.
- `loadCachedOutputs(cacheKey:): using cache: ClangCompiler, nodeID 24` — that node was
  scheduled, looked up its inputs, and did not run.

The prompt does not draw that distinction; the server's terminal is where you see it. The
node numbers below are from one walk-through and will differ from yours — what matters is
which nodes come back, and with which of the two lines.

**1. Build again.**

```
build hello --into ~/semel-playground/out
```

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
Settled.
No errors.
Exported 3 files into /Users/you/semel-playground/out
```

Every push says `[no change]`, no `output:` line appears, and the server's terminal prints
nothing at all. Nothing ran, because no wire changed, so no node was scheduled. (`Exported
3 files` is the export copying what is already there; it is not a rebuild.)

**2. Change one file.** In the **shell** terminal, edit
`~/semel-playground/hello/src/hello2.c` — change the text it prints — then build at the
**prompt**.

```
Push folder: hello
Push file: hello/hello.fmla [no change]
Push file: hello/src/common.h [no change]
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello.h [no change]
Push file: hello/src/hello2.c
Push file: hello/src/main.c [no change]
output:/hello/hello: OK
output:/hello/hello.dylib: OK
Settled.
No errors.
```

One file pushed without `[no change]`; two of the three products republished, and
`config.txt` not. The server:

```
processWithCatch(input:): ClangIncludeFinder, nodeID 32
processSomeNodes(): batch: 2 scheduled, 1 computed
processWithCatch(input:): ClangPreprocessor, nodeID 25
processSomeNodes(): batch: 1 scheduled, 1 computed
processWithCatch(input:): ClangCompiler, nodeID 24
processSomeNodes(): batch: 1 scheduled, 1 computed
processWithCatch(input:): ClangLinker, nodeID 17
processWithCatch(input:): ClangLinker, nodeID 29
processSomeNodes(): batch: 2 scheduled, 2 computed
```

One preprocess–compile chain reran, then both links, because both products take that
object. `hello.c` and `main.c` were not touched: one preprocessor and one compiler are
named here, not three of each.

**3. Put it back.** Undo the edit and build. The prompt prints exactly what it printed
last time, line for line — the same file pushed, the same two products republished. The
server does not:

```
processWithCatch(input:): ClangIncludeFinder, nodeID 32
processSomeNodes(): batch: 2 scheduled, 1 computed
loadCachedOutputs(cacheKey:): using cache: ClangPreprocessor, nodeID 25
processSomeNodes(): batch: 1 scheduled, 1 computed
loadCachedOutputs(cacheKey:): using cache: ClangCompiler, nodeID 24
processSomeNodes(): batch: 1 scheduled, 1 computed
loadCachedOutputs(cacheKey:): using cache: ClangLinker, nodeID 17
loadCachedOutputs(cacheKey:): using cache: ClangLinker, nodeID 29
processSomeNodes(): batch: 2 scheduled, 2 computed
```

The same nodes, in the same order, with a different verb. They were scheduled — a wire did
change — and every one of them was a cache hit. A *cache entry* is keyed on the node's
type, its properties and the name and content of everything wired to it; time appears
nowhere. Being **rescheduled** and being **recomputed** are different things, and most of
Semel's speed is the gap between them.

**4. Change a setting only the linker reads.** Add a line to
`~/semel-playground/clang.cfg`:

```
clang.linker.exampleSettingNobodyReads=1
```

```
push clang.cfg
build hello --into ~/semel-playground/out
```

```
Push file: clang.cfg
Push folder: hello
output:/hello/config.txt: OK
Push file: hello/src/hello.c [no change]
Push file: hello/src/hello2.c [no change]
Push file: hello/src/main.c [no change]
output:/hello/hello: OK
output:/hello/hello.dylib: OK
Settled.
No errors.
```

Not one C file changed, and both programs were relinked — the linkers' settings really did
change. What did not happen is the interesting part:

```
processWithCatch(input:): ConfigFilter, nodeID 19
processWithCatch(input:): ConfigFilter, nodeID 23
processWithCatch(input:): ConfigFilter, nodeID 21
processSomeNodes(): batch: 4 scheduled, 4 computed
loadCachedOutputs(cacheKey:): using cache: ClangPreprocessor, nodeID 25
loadCachedOutputs(cacheKey:): using cache: ClangPreprocessor, nodeID 22
loadCachedOutputs(cacheKey:): using cache: ClangPreprocessor, nodeID 27
processSomeNodes(): batch: 9 scheduled, 5 computed
loadCachedOutputs(cacheKey:): using cache: ClangCompiler, nodeID 20
loadCachedOutputs(cacheKey:): using cache: ClangCompiler, nodeID 24
loadCachedOutputs(cacheKey:): using cache: ClangCompiler, nodeID 26
processWithCatch(input:): ClangLinker, nodeID 17
processWithCatch(input:): ClangLinker, nodeID 29
```

All three selectors reran; all six preprocessors and compilers were woken and hit cache.
Each reads its settings through a `ConfigFilter` that passes on only `clang.compiler.*` or
`clang.preprocessor.*`, so what reached them was byte-identical and their keys did not
move. Nothing complains about the new key either: an unused key is only reported when it
falls under no selected prefix at all, and `clang.linker` is selected. The header comment
of
[`ConfigFilter.swift`](../../SemelCore/Sources/SemelCore/Nodes/ConfigFilter.swift) tells
this story in full, and it is seventy-five lines — read it now; it is the shape of the node
you are about to write.

`errors` shows what is wrong when a build fails; after a good build it says `No errors.`
`debug` dumps the whole graph — thirty-five nodes here, fourteen hundred lines. It is a
lot, and worth seeing once.

## Part 3 — Write a node

`MyLineCounter`: whatever files are wired to it, it outputs one `name: count` line per
wire. No tool, no configuration — everything a node must have, and nothing else.

This is the part that does touch the checkout, and it has to: node types are compiled into
`semelserv`, so your node has to live in a package the server links. "Cleaning up" at the
end puts the checkout back.

A finished copy is in
[`SemelExamples/Sources/SemelExamples/LineCounter.swift`](../../SemelExamples/Sources/SemelExamples/LineCounter.swift).
Write your own beside it as `MyLineCounter.swift`; two types in one module cannot share a
name, and the name is yours to choose anyway.

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
        for name in wires.keys.sorted() {
            let text = try wires[name]!.expectValue().resolveAsString()
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
  `ConfigFilter` skips such a wire instead; its header comment says why. For a count, a
  silent omission would be a wrong answer that looks right.
- `sorted()`, because a dictionary's order changes from one process to the next and your
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
restart it: stop `semelserv` in the **server** terminal, `swift build` in the **shell**,
then start `semelserv` again. The prompt can stay open. The graph is in the database; it is
still there when the server comes back, and nothing is rescheduled by the restart.

One snag on the way. `swift build` from the repository root may not notice a file you have
just **added** to a package it depends on by path: the build plan under `.build` is cached,
and the stale one still lists only the files that were there before. If the compiler says
`cannot find 'MyLineCounter' in scope` about the file you are looking at, `rm
.build/debug.yaml` and build again.

## Part 4 — Use it

In the **shell** terminal, add one line to `~/semel-playground/hello/hello.fmla`:

```
product "lines.txt" = MyLineCounter(input: [{f: <src/*.c>} "%%f.0%%.c": StaticFile(path: f)])
```

`{f: <src/*.c>}` makes one wire per matching file. The string before the colon is the wire's
name, and `%%f.0%%` is what the `*` matched — so the wires are named `hello.c`, `hello2.c`,
`main.c`. Write `%%f%%` instead and the wire is named for the whole mounted path —
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
output:/hello/lines.txt: OK
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

First, at the **prompt**, take the product out of the formula: delete the `lines.txt` line
from `~/semel-playground/hello/hello.fmla` in the **shell** terminal, then

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
swift build
```

Restart `semelserv`, and `git status` is clean.

Do it the other way round — remove the type first — and the next build that wakes the node
says so:

```
❌ ProjectBuilder  'input:/hello/hello.fmla'
   · products, status: no type is registered for kind 37
```

The way out is the same step you skipped: delete the `lines.txt` line from the formula and
build again. That clears the error, though the server may keep printing a bare
`The operation couldn’t be completed. (SemelNodeKit.TypeRegistryError error 1.)` while a
stale row survives; `reset` discards everything derived and rebuilds from what was pushed,
and after it the line is gone for good.

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
