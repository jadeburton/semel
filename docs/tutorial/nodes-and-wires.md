# Nodes and wires

The model behind everything in [Your first node](first-node.md), in eight pictures. Read
it before Part 3, where you write a node, or whenever one of its words stops making sense.
Nothing here is typed at a prompt; it is what the prompt's commands do to the graph.

The example node, `CapitalizerNode`, does not exist in the repository. It takes text and
gives it back twice, all upper case and all lower case — small enough that nothing about
the model hides behind what the node does.

## 1. A node has ports

A *node* is one step of a build, resident in the graph: it lives in the database and
re-runs when what it reads changes. It has input *ports* and output *ports*, usually at
least one of each. A few system nodes are the exceptions that make the rule visible:
`StaticFile` has no input port — a push fills it — and a product's `OutputFile` is where a
chain ends.

```
                                     ┌───────────────────┐
                                     │                   ├──▶ uppercaseValue
   originalValue ──▶                 │  CapitalizerNode  │
                                     │                   ├──▶ lowercaseValue
                                     └───────────────────┘
```

A *value* is a binary blob — the contents of a file, the output of a tool. On a wire it
travels as the hash of that blob in the object store, so "did this change?" is always one
comparison and never a diff.

## 2. A port holds named wires

A *wire* connects an output port to an input port and carries the value. A port may hold
any number of wires; most nodes need at least one on each input port to do anything. Two
wires into one port would be indistinguishable, so every incoming wire has a **name**,
which says what its value means to the node reading it:

```
   StaticFile(path: 'cat.txt') ──── cat-txt ──┐
                                              ├──▶ originalValue ──▶ CapitalizerNode ──▶ …
   StaticFile(path: 'dog.txt') ──── dog-txt ──┘
```

What `CapitalizerNode` receives on `originalValue` is an associative array, name to value:
`["cat-txt": …, "dog-txt": …]`. It could concatenate the two and capitalise that. In Part
3, `MyLineCounter` prints one line per name — the name is the label on its output.

## 3. One output, many wires

An output port pushes one value through however many wires leave it:

```
                                    ┌── animals-upper ──▶ product "animals-upper.txt"
   CapitalizerNode ─ uppercaseValue ┤
                                    └── animals-upper ──▶ product "animals-upper-duplicate.txt"

                   ─ lowercaseValue ──── animals-lower ──▶ product "animals-lower.txt"
```

The value is computed once. Every consumer reads the same hash, and a change to it wakes
all of them — that is the cascade Part 2 counted in `scheduled`.

## 4. Static ports

Everything so far is *static*: the wires into a port are created with the node, from what
the formula wrote, and are neither added to nor rewired afterwards. A node type declares
which ports it has in its descriptor, and a static input port is either `.required` —
wired at creation or the node cannot be made — or `.optional`, which the formula may leave
empty (`TreeMerger`'s `input` is one).

## 5. Dynamic ports

A *dynamic* input port starts with no wires at all:

```
   inputValue (dynamic) ──▶ ┌────────────────────┐
                            │ DynamicExampleNode ├──▶ output
                            └────────────────────┘
```

Output ports are never dynamic. What a node produces is fixed by its type; what it needs
can depend on what it reads — a C file's `#include` lines, a package manifest's
dependencies — and that is what a dynamic port is for.

## 6. A spec asks for wires

A node fills its own dynamic port by returning a *spec* for it: for each wire it wants,
the name and the node that should feed it, written in the same language a formula uses.
Semel then creates that node and the wire — or finds a node that already matches, and
wires that:

```
   inputValue (dynamic) ──▶ ┌────────────────────┐
             ▲              │ DynamicExampleNode ├──▶ output
             │              └────────────────────┘
             └─ ─ ─ ─ ─ ─ spec for 'inputValue': ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
                                                   dog-txt: StaticFile(path: 'input:/dog.txt').output
                                                 └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
```

In code that is the `inputWireSpecs` every `process` returns, keyed by port and then by
wire name; `MyLineCounter` returns `[:]` because it has no dynamic port. A node builds the
tree rather than writing the text — `.staticFile(at: path)`, or
`GraphSpecNode(ClangIncludeFinder.self, inputs: [...]).port(...)` from a node type and its
port constants — and the engine hashes it into the identity it matches by, parsing
nothing. The text above is how the same tree reads in a formula. `input:/` is the input
file system the push path fills — a formula writes `<dog.txt>` and the parser expands it.

## 7. It usually takes two passes

The first time a node with a dynamic port runs, the port is empty: the node cannot produce
its output, so it says what it needs and produces nothing. Semel wires what the spec asked
for; when a value arrives on the new wire, the node is scheduled again, and this time it is
satisfied:

```
   StaticFile(path: 'dog.txt') ──── dog-txt ──▶ inputValue (dynamic) ──▶ DynamicExampleNode ──▶ output
                                                                            spec for 'inputValue':
                                                                              dog-txt: StaticFile(path: 'input:/dog.txt').output
```

Two passes is the common case, not the limit. `ClangPreprocessor` has two dynamic ports:
on one it asks for a `ClangIncludeFinder` over its source file — a small static node that
lists the quoted `#include`s — and on the other for each header that list names, plus a
finder over each of those; it keeps asking until a round finds nothing new, and only then
runs the preprocessor. The specs it returns are exactly the shape above:

```
includeFileLists:  main.c: ClangIncludeFinder(sourceFile: ['input:/src/main.c': StaticFile(path: 'input:/src/main.c').output]).includePathList
headerInputFiles:  input:/src/hello.h: StaticFile(path: 'input:/src/hello.h').output
```

[`ClangPreprocessor.swift`](../../SemelClang/Sources/SemelClang/ClangPreprocessor.swift)
is the smallest real node that does this.

## 8. A spec names a whole branch

A spec is not limited to one node. It can describe the entire subgraph that should feed a
wire, and Semel matches it against what exists — so a branch two consumers describe the
same way is built once and shared:

```
   RedNode(param: 'X') ──┐
                         ├──▶ GreenNode ──── green ──▶ inputValue (dynamic) ──▶ DynamicExampleNode ──▶ output
   BlueNode ─────────────┘
                                          spec for 'inputValue':
                                            green: GreenNode(input: ['red': RedNode(param: 'X').output,
                                                                    'blue': BlueNode().output]).output
```

This is the same matching a formula's products go through: every node's rendered spec is
stored beside it, and "find or create the node that matches this text" is the one operation
the graph is built with, whether the text came from a formula or from a node's own
demand. It is also why a spec's text is part of a node's identity, and why renaming a node
type renames every node below it.

## 9. A value can be nothing

A wire does not always carry a value. When it does not, it carries the **reason** instead —
still waiting for one (`pending`), the producer has not run yet (`initializing`), an input
of the producer was missing (`inputNotProduced`) or itself broken (`inputInError`), the
source was removed (`deleted`), or the producer failed, with its message (`error`). A node
reading such a wire usually cannot do its work, and its own outputs become nothing with the
reason that points upstream:

```
                       ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐                          ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
                         No value — error!                              No value — inputInError
                       └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘                          └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘
   originalValue ──▶ UnhappyNode ──── someName ──▶ originalValue ──▶ CapitalizerNode ──▶ uppercaseValue
                                                                                      ──▶ lowercaseValue
```

That is how errors travel through the graph without anything catching and rethrowing
them, and how the settle report folds a cascade onto its cause: the one node whose reason
is `error` is the failure, and the nodes below it "carry it". A node may decide otherwise
for a particular port — `ConfigFilter` treats a config file nobody has pushed as nothing to
add rather than as a failure — which is a decision about which node reports, not a way of
making the absence fine.

## Where this leaves you

Part 3 of [Your first node](first-node.md) writes a node with one static input port; the
"Where next" table at its end names the smallest real node for each thing this page drew.
The words used here are the [glossary](../../AGENTS.md#glossary)'s.
