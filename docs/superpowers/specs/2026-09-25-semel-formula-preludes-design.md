# Formula preludes: built-in functions a node package registers (B-108)

## The problem

A straightforward project should have a straightforward formula. Today a C library that
any reader would describe as "build `src/*.c` into a dylib" takes the author through the
config file, a settings selector per tool, a preprocessor → compiler → linker chain, a
for-each over the files, and the naming of every wire:

```
func rawConfig() = StaticFile(path: <../clang.cfg>)

func config(prefix) = ConfigFilter(prefix: prefix, input: [rawConfig()])

func preprocessor(path) = ClangPreprocessor(
  configuration: [config(prefix: 'clang.preprocessor')],
  input: [path: StaticFile(path: path)]
)

func make(glob, dynamicLibrary) = ClangLinker(
  configuration: [Configuration(inherit: [config(prefix: 'clang.linker')], dynamicLibrary: dynamicLibrary)],
  objectFiles: [{f: glob} "%%f%%.o": ClangCompiler(configuration: [config(prefix: 'clang.compiler')], input: ["%%f%%.p": preprocessor(path: f)])]
)

product "hello.dylib" = make(dynamicLibrary: 'true', glob: <src/*.c>)
product "hello" = make(dynamicLibrary: 'false', glob: <src/*.c>)
```

Those fifteen lines are copied almost verbatim across all three C fixtures, and the one
decision in them that takes expertise — `%%f%%` versus `%%f.0%%` as a wire name — is the one
`FUTURE.md` records the tutorial getting wrong. The same shape repeats for an app bundle
(`HelloApp/semel.fmla`: compile, link, assets, strings, Info.plist, merge).

The intent of that formula is two lines:

```
include 'clang'

product "hello.dylib" = clang.dynamicLibrary(sources: <src>, settings: <../clang.cfg>)
product "hello"       = clang.executable(sources: <src>, settings: <../clang.cfg>)
```

## Decisions

*Vocabulary.* `AGENTS.md` reserves **toolchain** (tool discovery and versioning, "not a set of
node functions") and **plugin** (a `CommandPlugin` or `ProjectBuilderPlugin`). A prelude is a
set of node functions, so this document says *node package* — `SemelClang`, `SemelSwift`,
`SemelApple` — for what registers one.

- **A formula names no node package until it includes one.** The formula language and the
  engine are agnostic of every package of node types; a formula that uses a package's
  functions says so with an explicit `include` line. Nothing is in scope by default.
- **Each node package registers its own prelude.** A prelude is formula text — `func`
  definitions only — that a package such as `SemelClang` registers under a name when the
  server starts, the way it registers its node types and tool finders today. All packages
  ship one: `clang`, `swift`, `apple`.
- **Sources are named explicitly, as a folder.** `sources: <src>`. The prelude decides
  which files in it a tool takes (`*.c`, `*.cpp`, …); the formula decides where they are.
  A default source folder would be an input nobody can see in the formula.
- **A built-in expands to ordinary nodes.** A prelude call produces the same kind of graph
  a hand-written formula does — the per-file preprocessor and compiler nodes stay visible
  to `ls`, `errors`, `check` and the cache. No composite node types, and no engine knowledge
  of any package's nodes. When a built-in does not fit, the reader copies its body out of the
  prelude and edits it.

## Language

### `include '<name>'`

A string include names a registered prelude. It is an extension of today's `include`,
whose expression must evaluate to a node (`FormulaParser.swift:884`): a string is currently
a type error, so the new form takes a spelling nothing accepts today.

- The prelude's funcs enter scope **namespaced by the include name**: `include 'clang'`
  makes `clang.executable(…)` callable and nothing else. A bare `executable` stays free for
  the formula's own use, and two preludes may both define `library`.
- An unknown name is a parse error that lists the registered names.
- A prelude may include another prelude (`apple` includes `swift`); the inner funcs are
  reachable inside the outer prelude by their own namespace, and in the formula only if
  the formula includes that prelude itself.
- A prelude holds funcs only. A `product` in prelude text is an error at registration — a
  product there would be published in every project that includes it.

### Dotted calls

`IDENT '.' IDENT '(' args ')'` is a call to a namespaced func. It does not conflict with the
port suffix, which only follows `)`: `clang.objects(sources: <src>, settings: <x>).output`
parses as a call and then a port.

### Parameters are lexically scoped and bound

Two changes to how a func sees names, both needed before text written by one author runs
inside a formula written by another:

1. **Lexical scope.** Today a func body starts from the caller's environment and for-each
   bindings (`FormulaParser.swift:960`, `:987`), so a `%%f%%` in a prelude expands to the
   caller's `f`. A func body sees its parameters and its prelude's funcs, and nothing of
   the caller's.
2. **Every parameter is bound.** A call that leaves a parameter unbound is an error naming
   it. Today it errors only if the body happens to reference the name, or silently picks up
   a same-named variable from the caller.

No default parameter values. A structural variant is its own func (`executable`,
`dynamicLibrary`), which keeps each call's meaning readable at the call site; tool settings
keep the no-defaults rule of the configuration design.

### Parameters in templates

A parameter can be used in a path or for-each template: `{file: '%%sources%%/*.c'}`. Today
templates substitute only for-each bindings (`FormulaParser.swift:771-785`), which is why
the fixtures pass whole globs. This is what lets the formula name a folder and the prelude
name the pattern.

## Registration

A registry in `SemelNodeKit`, shaped like `ToolNamespaceRegistry`: idempotent, keyed by
name, sorted when listed. A node package depends on `SemelNodeKit` alone, so this
keeps the rule that no toolchain package imports the engine.

```swift
FormulaPreludeRegistry.register(name: "clang", text: clangPrelude)
```

called from `SemelClang.register()` beside `TypeRegistry.register(types:)`. The text lives
in the package as a `.fmla` resource, so it reads, lints and diffs as a formula.

### How prelude text reaches a formula

It must arrive **on a wire**. `ProjectBuilder` is cacheable, and text that reached it any
other way would be missing from its cache key; worse, a resident builder would not re-run
when a server upgrade changes the prelude, so the graph would keep what the old text
expanded to.

So a prelude is a source node, filled by the runtime rather than by a wire — the shape
B-43 proposes for `StaticFile`'s pushed content:

- A core node type `FormulaPrelude(name:)` with one output port, `formula`, and no inputs.
- When the engine starts, it writes each registered prelude's text to its node's port
  where the text differs from what is stored, exactly as a push writes a `StaticFile`.
- `ProjectBuilder` resolves `include 'clang'` by wiring `FormulaPrelude(name: 'clang').formula`
  on its `includes` port, the same path a converter's `.formula` takes today. A changed
  prelude wakes that wire, the builder re-runs, and every node whose spec moved is a new
  node; the rest keep their identity and their cache.
- A formula that includes a name no package registered gets a `FormulaPrelude` whose port
  says so, and the error report names the include line.

## The preludes

The first cut of each, as the acceptance surface. The bodies are ordinary formula text over
the node types each package already has.

### `clang`

```
func settings(file, prefix) = ConfigFilter(prefix: prefix, input: [StaticFile(path: file)])

func preprocessed(file, settings) = ClangPreprocessor(
  configuration: [clang.settings(file: settings, prefix: 'clang.preprocessor')],
  input: [file: StaticFile(path: file)]
)

func objects(sources, settings) = …   // one ClangCompiler per '*.c' / '*.cpp' in sources,
                                      // wires named by the captured stem ("%%f.0%%.o")

func executable(sources, settings)     = ClangLinker(configuration: […, dynamicLibrary: 'false'], objectFiles: […])
func dynamicLibrary(sources, settings) = ClangLinker(configuration: […, dynamicLibrary: 'true'],  objectFiles: […])
```

`objects` is exposed so a formula can link objects from two folders or add libraries. No
`staticLibrary`: `ClangLinker` produces executables and dylibs only, and an archive needs
its own node.

### `swift`

Hand-written Swift targets outside a package — HelloApp's executable is the case:

```
func module(sources, name, settings)     = SwiftCompiler(…).object
func executable(sources, name, settings) = SwiftLinker(… linkage: 'executable', outputName: name …).output
func library(sources, name, settings)    = SwiftLinker(… linkage: 'staticArchive' …).output
```

A `Package.swift` keeps `include SwiftFormulaConverter(path: <.>).formula`: the converter
already turns a package into its formula, and a prelude func cannot do what it does,
because a func cannot contain an `include`.

### `apple`

```
include 'swift'

func assets(catalog, appIcon, settings) = AssetCatalogCompiler(…)
func strings(catalog, settings)         = StringCatalogCompiler(…).files
func app(name, sources, assets, strings, infoPlist, settings) = TreeMerger(…).files
```

`app` returns the whole bundle as one tree: `TreeBuilder` places the executable,
`Info.plist` and `PkgInfo` at their entry paths, `TreeMerger` adds the compiled resources.
HelloApp's formula becomes one product:

```
include 'apple'

product 'Hello.app/' = apple.app(
  name: 'Hello',
  sources: <Sources>,
  assets: apple.assets(catalog: <Assets.xcassets>, appIcon: 'AppIcon', settings: <semel.config>),
  strings: apple.strings(catalog: <Resources/Localizable.xcstrings>, settings: <semel.config>),
  infoPlist: <Info.plist>,
  settings: <semel.config>
)
```

## Settings

The settings file is a parameter, like the sources: which file configures the build is a
fact about this project, and a prelude that assumed `semel.config` beside the formula would
be an input the formula does not show. The prelude derives each tool's prefix from the node
type — the fact `FUTURE.md` notes every hand-written formula restates — so the formula names
the file once per call rather than once per tool.

## Constraints and what is out

- **Flat source folders.** Globs match one level of a folder manifest; `**` does not recurse
  (`ProjectBuilder` matches per segment). A project with nested sources is out of the first
  cut; the fix belongs in the wildcard matcher, not the preludes.
- **A pending include blanks the formula's products** until it arrives
  (`FormulaParser.swift:96`). Prelude nodes are filled at start-up, before any builder runs,
  so this does not bite them; it is worth fixing for converters separately.
- **Unused settings.** `BuildEngine.unclaimedConfigKeys` reports keys no `ConfigFilter`
  selects; a prelude that selects fewer namespaces than a shared config provides will
  report the rest, as a hand-written formula does today.
- **No macros, no conditionals.** A prelude is funcs over nodes. Anything that needs to read
  a file to decide the graph is a converter node, as `Package.swift` is.

## Acceptance

1. `EndToEnd/Fixtures/c`, `cpp` and `tutorial` rewritten to `include 'clang'`; their products
   match the hand-written formulas' byte for byte under the harness's four cold builds.
2. `EndToEnd/Fixtures/swift/HelloApp` rewritten to `include 'apple'`; the bundle matches and
   launches in the simulator.
3. Formula parser tests: namespaced resolution; an unknown include name; a formula func
   with the same bare name as a prelude func, both callable; lexical scope (a prelude's
   `%%f%%` does not see the caller's `f`); an unbound parameter; a parameter in a template;
   a product in prelude text refused at registration.
4. Changing a registered prelude's text and restarting the server re-runs the builders that
   include it and no others.
5. The tutorial's Part 3 formula is written with `clang.` calls first, and the hand-written
   chain is shown afterwards as what the call expands to.

## Open questions

- **`include 'clang' as c`** — an alias costs one grammar rule. Not needed until two
  preludes want the same name.
- **A `semel expand <formula>` command** printing a formula with its prelude calls expanded
  would make the expansion inspectable without reading the prelude. Useful, not required.
