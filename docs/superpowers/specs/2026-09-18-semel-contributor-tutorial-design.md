# A first tutorial: build, watch the cache, write a node

**Status:** design approved 2026-09-18; not implemented.

## 1. Why

The README is a reference — command tables, then a section per capability — and
`AGENTS.md` holds a good glossary and the invariants. Both are correct and neither is a way
in. A newcomer meets `ls -o`, `nudge` and "wires" before seeing anything build, and the
glossary defines node, wire, port, spec, formula and product one at a time without ever
showing them working together. Whoever wants to contribute today reverse-engineers that
from `SwiftCompiler`, which is the wrong first node to read.

The tutorial is the connective tissue: one path, taken by hand, from a clone to a node the
reader wrote themselves running inside a build.

**Reader.** A future contributor: comfortable with Swift and a terminal, has used some
build system, has never seen Semel. Not an app developer who wants their project built
(that is `prepare` and the README), and not yet someone working on the engine.

**End state.** The reader has built a C program with Semel, has seen for themselves what is
and is not redone when something changes, and has written a node type, registered it,
called it from a formula and watched it be cached. They know which file to read next for
each thing the tutorial left out.

## 2. What is delivered

```
docs/tutorial/
  first-node.md                     # the tutorial
SemelExamples/                      # a package like SemelApple, the reference copy
  Package.swift
  Sources/SemelExamples/
    SemelExamples.swift             # register()
    LineCounter.swift
  Tests/SemelExamplesTests/
    LineCounterTests.swift
EndToEnd/Fixtures/tutorial/         # the C hello sources plus the Part 4 formula
  hello.fmla
  src/
```

plus one line in `semel-server/main.swift` (`try SemelExamples.register()`), the package in
the root `Package.swift`, a `Projects.tutorial` roster entry among the fixtures, a link to
the tutorial from the top of the README's Usage section, and a "Choosing a `kind`"
paragraph in `AGENTS.md` (Section 6).

## 3. The tutorial

One document, four parts, about half an hour. Every command is one the reader can paste;
every output shown is real output, trimmed. Terms are introduced where they first do
something and link to the `AGENTS.md` glossary rather than being redefined. The word
*plugin* is not used for a node module: `AGENTS.md` reserves it for `CommandPlugin` and
`ProjectBuilderPlugin`.

### Part 1 — Build something

Clone, `swift build`, start `semelserv`, start `semel`. The reader copies
`EndToEnd/Fixtures/c` to a scratch folder as `hello/`, so nothing they do dirties the
checkout, and writes their config beside it as `clang.cfg` — the formula reads
`<../clang.cfg>`, a sibling of the build folder, so it is pushed on its own before the
build. (`Fixtures/tutorial` is where the tutorial *ends*; Parts 1 and 2 start without the
new node.)

The config is the frightening part of a first session — 25 lines of `toolDescriptor.*` that
must match the machine — so the tutorial does not ask anyone to write it: the `tools`
command prints the blocks ready to paste, and the text says which two values
(`sdkPath`, `target`) to add and where `xcrun` prints them. The fixture's template
(`clang.cfg.template`) stays what the test harness renders; the reader's file is their own.

`push clang.cfg`, `build hello --into ./out`, run `./out/hello`. Then `hello.fmla` is read line by line beside a
drawing of the graph it becomes: `StaticFile` → `ClangPreprocessor` → `ClangCompiler` →
`ClangLinker` → the product. Introduces *formula*, *node*, *wire*, *port*, *product*.

### Part 2 — Watch it not work

No code. Four experiments, each with the command, what to look for and one paragraph on why:

1. Build again: nothing runs.
2. Edit `hello2.c`: its preprocess–compile chain and the two links rerun; `hello.c` and
   `main.c` do not.
3. Revert the edit: everything is a cache hit, including the links — the key is content,
   not time.
4. Change a setting only the linker reads: the compilers are woken and hit cache. This is
   the `ConfigFilter` story, and the text points at that file's header comment rather than
   retelling it.

`ls -o`, `errors` and `debug` are introduced as the instruments for these, not as a table.
Introduces *cache entry*, *pinned*, and the difference between being rescheduled and being
recomputed.

### Part 3 — Write a node

`LineCounter`: wires arrive on one input port, named by the formula; the output is text,
one `name: count` line per wire, sorted by name. Pure — no tool, no sandbox, no
configuration — about forty lines, in the shape of `ConfigFilter`.

Chosen over a concatenator or an uppercaser because its output visibly depends on each
input separately: editing one file changes exactly one line of the product, which is what
Part 4 needs to show.

The reader writes theirs as `MyLineCounter`, in a file of their own inside
`SemelExamples`, with the next unused `kind`, and adds it to the `register()` list; the
committed `LineCounter.swift` is there to compare against. Two types in one module cannot
share a name, and a second name and number make the point that both are the author's to
choose. The tutorial's formula line uses `MyLineCounter`; the fixture's uses `LineCounter`. Covered, in the order the
compiler demands them: `kind` and how to choose one, `thisNode` and `init`,
`NodeDescriptor` and its ports, `process(input:)`, `NodeValue.expectValue()`, resolving a
hash to text, `intern()`, `ProcessOutput`. Then `register()`, and that the server is
rebuilt: toolchains are linked into `semelserv`, there is no loading at run time.

What a ghost or errored input wire should do is stated once, with `ConfigFilter`'s reasoning
linked: `LineCounter` fails on one, because a count that silently omits a file is wrong in
a way a filtered config is not.

### Part 4 — Use it

One line added to the formula:

```
product "lines.txt" = LineCounter(input: [{f: <src/*.c>} "%%f%%": StaticFile(path: f)])
```

Build; read `lines.txt`. Edit a file: one line changes, and the C products that do not
depend on that file are untouched. Revert: cache hit. Add a file matching the glob: a new
wire appears without the formula changing.

**Next steps**, each a link to the smallest real example: a node that runs a tool
(`StringCatalogCompiler`, 85 lines — `ToolRunner`, `ToolDiscovery`, a config namespace);
tree outputs (`AssetCatalogCompiler`); a node that emits formula text
(`SwiftFormulaConverter`, with a warning about its size); dynamic input ports and
`inputWireSpecs` (`ClangIncludeFinder`); `AGENTS.md` for the invariants and the deliberate
choices.

### Left out on purpose

Swift packages and `prepare`, the Xcode converter, the daemon split and the protocol,
the cache server and multiple users, and the engine's internals beyond two sentences on
the two-phase loop. Each has a home already; the tutorial links to it and moves on.

## 4. `SemelExamples`

A package beside `SemelApple`, depending on `SemelNodeKit` only. `SemelExamples.register()`
registers `LineCounter` with `TypeRegistry` and nothing else — no tools, no namespaces.
It is always registered by `semelserv`: a flag would mean the tutorial's first instruction
is how to turn the tutorial on, and one inert node type costs nothing. The module is for
nodes that exist to be read; nothing a real build depends on goes there.

Unit tests follow the toolchains' pattern: two wires in, the expected text out; an errored
wire throws; wire order does not change the output.

## 5. Keeping it true

A tutorial that has drifted is worse than none, so what can be tested is:

- `EndToEnd/Fixtures/tutorial` is the Part 4 state — the C sources and the formula with
  the `lines.txt` product. `Projects.tutorial` (`alsoPush: ["clang.cfg"]`, like `cHello`)
  builds it with the other fixtures on every
  `swift test`, twice in two homes like the rest, expecting `hello`, `hello.dylib`,
  `config.txt` and `lines.txt`. If the node, the formula syntax or the registration breaks,
  the suite says so.
- The fixture shares `src/` content with `Fixtures/c` by copy, not by reference: a fixture
  is pushed as a folder, and the C fixture is slated to go once a real C project is pinned
  (B-79) while this one stays.

What cannot be tested is the prose and the pasted output. The tutorial names the commit it
was last walked through at, and `AGENTS.md`'s section on tests gains a line: a change to a
REPL command's name or output that the tutorial shows updates the tutorial in the same
commit.

## 6. `AGENTS.md`: choosing a `kind`

`Node.kind` is a hand-assigned `UInt` that `TypeRegistry` uses to bring a stored node back
as its type; 1–35 are in use with gaps, and nothing written says how to pick one. The
paragraph states the rule — the next unused number above the highest in the repository,
never a gap (a gap may be a removed type whose rows are still in someone's database), never
reused — and where to look (`grep -rn "static let kind" Semel*/Sources`). Whether
`TypeRegistry.register` already refuses a duplicate is checked during implementation; if it
does not, that is a backlog item, not part of this work.

## 7. Open points, decided

- *One document or several pages?* One. Half an hour of reading does not need navigation,
  and one file is one thing to keep current.
- *Swift or C for the first build?* C. The hand-written formula shows the whole model in
  ten lines; the Swift path generates its formula, so the reader would see that it works
  and not how.
- *Should the reader's node live outside the repository?* It cannot: node types are linked
  into the server. The tutorial says so as a fact about the design.
