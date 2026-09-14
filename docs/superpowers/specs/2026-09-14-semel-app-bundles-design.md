# Building an app bundle: tree products, resource nodes, and the Xcode project

**Status:** design, 2026-09-14. Spike done the same day; parts 1 and 2 are the next work.
**Relationship:** extends the clone-to-build loop (B-57 to B-59) from a tree of Swift
packages to the app that consumes them. Nothing here changes what Semel knows: the engine
gets one generic feature (a product can be a folder of files a node produced), and the
Apple platform tools become a toolchain package like `SemelSwift` and `SemelClang`.

## What the spike showed

A SwiftUI app for the iOS simulator can be built by a hand-written formula **today**, with
no engine change, as three products under one folder name:

```
product 'Hello.app/Hello'      = SwiftLinker(... linkage: 'executable' ...).output
product 'Hello.app/Info.plist' = StaticFile(path: <Info.plist>).output
product 'Hello.app/PkgInfo'    = StaticFile(path: <PkgInfo>).output
```

`build HelloApp --into out` exports `out/Hello.app`, `simctl install` accepts it, and the
app launches and runs (`C1/swift/HelloApp`). The linker's output is ad-hoc signed by `ld`,
and the simulator asks for nothing more. So the executable, the bundle layout and the
export need no new machinery. What is missing is everything whose *file set is decided by a
tool*: an asset catalog compiles to `Assets.car` plus one PNG per app-icon size, a string
catalog to one `.lproj` folder per language. A formula cannot name those files, and today a
node cannot produce them: a port carries one value, and the sandbox reads back only the
output names it was told to expect.

## Part 1: tree-valued ports and tree products (engine)

**A tree value.** A port may carry a *tree*: a `TreeManifest` (in `SemelNodeKit`, beside
`FolderManifest`) listing relative paths, each with the content hash and the file mode.
It is an ordinary value — the manifest is interned and the port holds its hash — so
nothing about wires, caching or the database changes. What changes is that a node can now
say "here are N files" on one port.

**Producing one.** `ToolRunner.execute` gains `expectedOutputFolders: [String]` beside
`expectedOutputFileNames`: every file under such a folder in the sandbox is interned and
collected, sorted by path, into a `TreeManifest`. A tool that writes a directory of
results, `actool` and `xcstringstool` among them, is then one node with one `files` port.

**Consuming one file of it.** A `TreeFile(name: 'Assets.car', tree: ['tree': <expr>])`
node has one static port carrying a tree and one property naming an entry; its `output`
is that entry's content and its `fileMetadata` the entry's mode. It is the bridge from a
tree to the one-value world every existing node lives in.

**Publishing all of it.** A product whose name ends in `/` is a *tree product*:

```
product 'Hello.app/'  = AssetCatalogCompiler(...).files
```

`ProjectBuilder` wires the expression into a new optional `trees` port keyed by the
product path — the same move it makes for the folder manifests behind a wildcard — and,
once the value has arrived, emits one `OutputFile` per entry at `<product path><entry
path>`, each wrapping a `TreeFile`. Until then the tree's products are simply absent, as a
wildcard's are before its folder manifest has been read. Two tree products may share a
folder (`Hello.app/` from the asset compiler and again from the string compiler); two
entries at one path are an error reported on the builder, not a last-writer-wins.

Why the trailing slash and not a keyword: the language already says "this name gets this
value"; a name that is a folder says "these names get these values". No new word, nothing
toolchain-specific, and a plain `product 'Hello.app/Assets.car' = ...` still works when
the file set is known.

Not in this part: a tree as *input* to a tool other than through `TreeFile`. A node that
wants a whole tree in its sandbox (a signer, an assembler) gets `treeFiles`-style input
when the first such node exists.

## Part 2: the Apple resource nodes (`SemelApple`)

A new toolchain package, `SemelApple`, depending on `SemelNodeKit` only. The tools here
are Apple platform tools, not Swift tools: `SemelSwift` compiles Swift wherever `swiftc`
runs, and these compile resources for Apple bundles whatever language the code is in.

- **`AssetCatalogCompiler`** runs `actool`. Input: the catalog folders (`.xcassets` and
  `.icon`) through folder manifests, walked to every file the way `SwiftCompiler` walks its
  `inputFolder` and `inputSubfolders` — that walk is moved into `SemelNodeKit` as a helper
  both use. Settings: platform, minimum deployment target, target devices, app icon name.
  Outputs: `files` (a tree: `Assets.car` and the icon PNGs) and `partialInfoPlist`.
- **`StringCatalogCompiler`** runs `xcstringstool compile` on one `.xcstrings` file.
  Output: `files`, a tree of `<language>.lproj/<table>.strings` for every language in the
  catalog. One node for all languages, which is what the tree is for.
- **`InfoPlistBuilder`** merges a base plist, any number of partial plists (actool's), and
  literal keys from its configuration (the `INFOPLIST_KEY_*` of a project), then
  substitutes `$(VAR)` references from its settings. No tool; `PropertyListSerialization`.
  Output: `plist`.

Namespaces `apple.assetCatalogCompiler`, `apple.stringCatalogCompiler`,
`apple.infoPlistBuilder` are registered like the others, `DefaultTools` learns the two
tool names, and `semel-swift prepare` writes their blocks. Signing is left out: the
simulator needs none beyond what `ld` does, and a device build's identity is a machine
fact that belongs in the config, later.

With parts 1 and 2 a hand-written formula builds the HelloApp bundle with an asset
catalog and a string catalog, and that is the milestone's test.

## Part 3: the Xcode project

`XcodeProjectConverter` reads `project.pbxproj` (a plist) and the `.xcconfig` files it
names, resolves build settings per configuration, and emits formula text: one tree of
products per native target — the executable, the compiled resources, the plain-copied
ones, the built Info.plist — an application as `<name>.app/`, an extension as
`<name>.appex/` embedded under the app's `PlugIns/`. Package dependencies the project
declares are named the way a package's are, so the existing converter and `Dependencies`
rule reach them. `semel-swift prepare` treats a folder holding an `.xcodeproj` as a root
and vendors what the project references.

This is the largest part and the last, because everything before it can be driven by a
hand-written formula, and because its output is only ever the formula parts 1 and 2 make
expressible. The acceptance test is IceCubesApp: `prepare`, `build --into`, `simctl
install`, launch.

## Order

1. Part 1, with `TreeFile` and a `RecordingToolRunner`-level test for output folders.
2. Part 2, verified on `C1/swift/HelloApp` extended with an asset catalog and a string
   catalog, launched in the simulator.
3. Part 3, verified on IceCubesApp.
