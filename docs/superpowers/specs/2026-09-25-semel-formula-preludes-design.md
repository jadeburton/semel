# Formula preludes: built-in functions a plugin provides (B-108)

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

*Vocabulary.* A **plugin** is a component that extends the agnostic core by registering with
it (`AGENTS.md`): `SemelClang`, `SemelSwift`, `SemelApple`. Linked into `semelserv` today;
meant to be loadable as a dylib from outside this repository one day, which the design must
not rule out (see "Toward loadable plugins"). **Toolchain** stays reserved for tool discovery
and versioning — a prelude is not one.

- **A formula names no plugin until it includes one.** The formula language and the engine
  are agnostic of every plugin; a formula that uses a plugin's functions says so with an
  explicit `include` line. Nothing is in scope by default.
- **Each plugin provides its own prelude.** A prelude is formula text — `func` definitions
  only — that a plugin such as `SemelClang` provides for an include name, registered when the
  server starts the way it registers its node types and tool finders today. All three
  plugins ship one: `clang`, `swift`, `apple`.
- **Sources are named explicitly, as a folder.** `sources: <src>`. The prelude decides
  which files in it a tool takes (`*.c`, `*.cpp`, …); the formula decides where they are.
  A default source folder would be an input nobody can see in the formula.
- **A built-in expands to ordinary nodes.** A prelude call produces the same kind of graph
  a hand-written formula does — the per-file preprocessor and compiler nodes stay visible
  to `ls`, `errors`, `check` and the cache. No composite node types, and no engine knowledge
  of any plugin's nodes. When a built-in does not fit, the reader copies its body out of the
  prelude and edits it.

## Language

### `include '<name>'`

A string include names a *virtual file*: text no file in the input file system holds, which
a plugin provides on request (see Registration). It is an extension of today's
`include`, whose expression must evaluate to a node (`FormulaParser.swift:884`): a string is
currently a type error, so the new form takes a spelling nothing accepts today.

- The prelude's funcs enter scope **namespaced**: `include 'clang'` makes
  `clang.executable(…)` callable and nothing else. A bare `executable` stays free for the
  formula's own use, and two preludes may both define `library`. The provider states the
  namespace, since a name such as `'clang/c++'` is not an identifier.
- A name no provider answers is an error naming the include line.
- A prelude may include another prelude (`apple` includes `swift`); the inner funcs are
  reachable inside the outer prelude by their own namespace, and in the formula only if
  the formula includes that prelude itself.
- A prelude holds funcs only. A `product` in provided text is an error — a product there
  would be published in every project that includes it.

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

Plugins **intercept include names**. Each registers a provider in `SemelNodeKit`, called
from its `register()` beside `TypeRegistry.register(types:)`; a plugin depends on
`SemelNodeKit` alone, so the core never names it and it never imports the engine.

```swift
public protocol FormulaIncludeProvider {
    /// What this plugin says about `name`: nil when the name is not this plugin's.
    func answer(forIncludeNamed name: String) -> FormulaIncludeAnswer?
}

public enum FormulaIncludeAnswer {
    /// The prelude: `namespace` is what `name.func(…)` calls are spelled with; `text` holds
    /// funcs only.
    case prelude(namespace: String, text: String)
    /// The name is this plugin's, and it cannot be provided here — the sentence the user
    /// reads: "no installed clang supports C++26 (found 17.0.0)".
    case refused(reason: String)
}

FormulaIncludeProviders.register(SemelClang.includeProvider)
```

A refusal is how a plugin tells the user *why* their include failed, where nil would leave
only "no plugin answers 'clang/c++26'". It claims the name as a prelude does, so it counts
under rule 2 below, and it is published on the node's port like any answer, so installing
the missing tool and restarting replaces it. When no plugin answers at all, the report lists
the registered providers' plugins, so the user sees what is installed.

A plugin whose prelude is fixed answers one exact name with a `.fmla` resource, so it
reads, lints and diffs as a formula; `FormulaPrelude.fixed(name:namespace:resource:)` is that
provider in one line. Interception is what a plugin needs beyond that: a family of names
(`'clang/c'`, `'clang/c++'` with the language standard's patterns and flags differing), or
text generated from what the plugin knows at start-up — the tools `ToolDiscovery` found,
the SDKs installed.

Three rules keep that flexibility inside the model:

1. **A provider is a pure function of the name and of what the server knew when it
   started.** It must not read the input file system or anything else that changes while
   the server runs: text computed from a project's files is a converter node's job, and
   `include SwiftFormulaConverter(path: <.>).formula` stays how a `Package.swift` is
   included. What a provider returns is asked once per name per start, and is what the
   `FormulaPrelude` node below publishes.
2. **Two providers answering one name is an error**, naming both plugins — the rule
   `TypeRegistry` applies to two types claiming one `kind`. Not first-wins: registration
   order would then decide what a formula means, silently.
3. **A provider answers the same name the same way within one start.** The engine asks
   once and keeps the answer, so a provider that did otherwise would disagree with itself
   only across restarts, which is what a changed prelude already means.

### How prelude text reaches a formula

It must arrive **on a wire**. `ProjectBuilder` is cacheable, and text that reached it any
other way would be missing from its cache key; worse, a resident builder would not re-run
when a server upgrade changes the prelude, so the graph would keep what the old text
expanded to.

So a prelude is a source node, filled by the runtime rather than by a wire — the shape
B-43 proposes for `StaticFile`'s pushed content:

- A core node type `FormulaPrelude(name:)` with one output port, `formula`, and no inputs.
- `ProjectBuilder` resolves `include 'clang'` by wiring `FormulaPrelude(name: 'clang').formula`
  on its `includes` port, the same path a converter's `.formula` takes today.
- Names cannot be enumerated in advance once plugins intercept them, so the node is filled
  **when it is created** — the engine asks the providers for its name and writes the answer
  to its port — and **when the engine starts**, for every `FormulaPrelude` already resident,
  writing only where the answer differs from what is stored, exactly as a push writes a
  `StaticFile`. A changed prelude wakes the wire, the builder re-runs, and every node whose
  spec moved is a new node; the rest keep their identity and their cache.
- A refused name publishes the plugin's reason as an error on the port, and a name nobody
  answers publishes "no plugin answers" with the installed plugins listed; the report names
  the include line either way. The node stays resident while a formula includes it, so installing a plugin
  that answers the name and restarting fills it.

## The preludes

The first cut of each, as the acceptance surface. The bodies are ordinary formula text over
the node types each plugin already has.

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
  cut; the fix belongs in the wildcard matcher, not the preludes. *Lifted 2026-09-28
  (B-108 residual 1):* `**` matches zero or more folders, `ProjectBuilder` walks down to
  the folders a pattern reaches, and `clang`'s `sources:` is read as `**/*.c`, `**/*.cpp`.
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
   a product in provided text refused.
4. Provider tests: two plugins answering one name is an error naming both, whether each
   provides or refuses; a refusal's reason is what the report says against the include
   line; a name nobody answers is reported with the installed plugins listed, and a restart with a plugin that answers
   it fills the resident node.
5. Changing a provided prelude's text and restarting the server re-runs the builders that
   include it and no others.
6. The tutorial's Part 3 formula is written with `clang.` calls first, and the hand-written
   chain is shown afterwards as what the call expands to.

## Toward loadable plugins

Plugins are linked into `semelserv` today. The aim is for the server to find plugin dylibs
and load them without their being part of this repository, and nothing here may depend on
a plugin being compiled in. What this design already gives a loaded plugin:

- **The core never names a plugin.** A provider is registered through `SemelNodeKit`, the
  same way from a dylib's entry point as from `SemelClang.register()`.
- **Two plugins claiming one include name fail loudly**, which matters most when the two
  were written by people who never met.
- **A replaced plugin's prelude reaches the graph.** Resident `FormulaPrelude` nodes are
  re-asked at every start, so a new dylib's text wakes exactly the builders that include it.
- **An absent plugin is a state, not a dead end.** A formula including a name nobody
  answers reports it against the include line and fills in when the plugin is installed.

What loading needs elsewhere, outside B-108:

1. **`kind` numbers.** One hand-assigned number space across every package works inside one
   repository and not across strangers' dylibs. A kind has to be qualified by its plugin,
   or replaced by the type name `TypeRegistry` already looks types up by (`FUTURE.md`
   already asks whether `kind` earns its place).
2. **A plugin's code in its cache keys.** `implementationVersion` is bumped by hand; a
   rebuilt dylib whose author forgot would hit entries its old code wrote. A fingerprint of
   the dylib in each of its types' keys closes that, as the tool binary's fingerprint does
   for tools (B-17).
3. **An ABI boundary.** Swift types cross a dylib boundary safely only from a module built
   with library evolution. Either `SemelNodeKit` is built that way, or a plugin exports one
   C entry point (`@_cdecl`) that calls its `register()` inside the dylib.
4. **Rows of an unloaded plugin's types.** Uninstalling a plugin leaves nodes of kinds
   nothing registers — today a dead end (B-83) — and loading makes that ordinary.

## Open questions

- **`include 'clang' as c`** — an alias costs one grammar rule. Not needed until two
  preludes want the same name.
- **A `semel expand <formula>` command** printing a formula with its prelude calls expanded
  would make the expansion inspectable without reading the prelude. Useful, not required.

## As built (2026-09-25)

Where the implementation departs from the design above, and why:

- **Prelude text is a Swift string literal**, not a `.fmla` resource: a resource bundle has
  to be found beside `semelserv` at run time, which is fragile; the text is still plain
  formula, and the settings prefixes are interpolated from each node type's own constant.
- **The app bundle stays a set of products.** `TreeBuilder` writes every entry with the
  default mode, so an executable placed in the bundle's tree would lose the bit that lets
  it launch. `apple` provides `assets`, `resources` (the asset catalog plus every
  `*.xcstrings` in a folder) and `infoPlist`; the executable is `swift.executableUsing`.
- **A target that imports a package is its own func** — `swift.moduleUsing`,
  `swift.executableUsing` — since the language has no optional parameters.
- **`infoPlist` takes the catalog folder**, not the compiled assets: a func cannot pick a
  port off a value it was handed. Rebuilding the compiler from the same arguments names the
  same node.
- **`semel-swift prepare`** wrote settings for the prefixes a formula spells out; a formula
  including a prelude spells none, so it reads each included prelude's text too.
- **The `cpp` fixture stays hand-written.** It exercises `ConfigMerger`, which a single
  `settings:` file cannot express.

What the clang and swift preludes build is node for node what the hand-written fixtures
built (`ClangPreludeTests`, `AppPreludeTests`), so a formula that moves to them keeps its
graph and its cache. Enforced since B-111 (2026-09-27): each text sees the namespaces it
includes itself, so a prelude that another prelude includes is callable inside that prelude
and from the formula only once the formula includes it too; the parser checks every dotted
call after merging and names the missing include.
