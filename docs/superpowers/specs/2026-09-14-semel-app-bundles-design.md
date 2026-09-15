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

### What IceCubesApp's project actually contains (2026-09-15 survey)

Five native targets: the application and four extensions (share, notifications,
widgets, action), each embedded in the app's `PlugIns/` by the one `PBXCopyFilesBuildPhase`.
No `PBXSourcesBuildPhase` lists a file: every target is a Xcode 16
`PBXFileSystemSynchronizedRootGroup` — the folder *is* the target's sources and resources,
with `membershipExceptions` naming what to leave out (`Info.plist`, files that belong to
another target). Fourteen local packages are plain `PBXFileReference` wrappers
(`Packages/Timeline`); four remote packages are `XCRemoteSwiftPackageReference`s. Every
target has `GENERATE_INFOPLIST_FILE = YES` with `INFOPLIST_KEY_*` settings and an
`INFOPLIST_FILE` holding the rest (URL types, fonts, `NSExtension`). Settings reference
`$(BUNDLE_ID_PREFIX)` and `$(DEVELOPMENT_TEAM)` from an xcconfig the developer copies from
a template; the Debug configuration's xcconfig does not exist in a fresh clone. Two things
the survey rules out: no storyboards, no `PBXSourcesBuildPhase` file lists; and two it
rules in: `.icon` folders as resources, and the app's asset catalog holding many icon sets.

### Consuming a package product from another formula

The app links what its packages compile, and imports their modules. Today a package
formula's linker node is inline in its `product` statement and unnameable from outside,
and the closure of targets behind a product is known only to `SwiftFormulaConverter`. So
the Swift converter emits, per product `P`, two funcs beside the product:

```
func modules_P() = TreeMerger(input: ['Timeline': compilerTimeline().swiftmodule, ...]).files
func objects_P() = TreeMerger(input: ['Timeline.o': compilerTimeline().object, ...]).files
```

— every transitive Swift target's module and object, and every C target's objects — and
`SwiftCompiler` gains an optional `moduleTrees` port (each entry placed under `modules/`,
one `-I modules`) while `SwiftLinker` gains an optional `objectTrees` port (every entry
linked). A formula that includes a package can then say `moduleTrees: ['Timeline':
modules_Timeline().files]`. The tree is doing exactly what it was built for: a file set
decided elsewhere, carried on one port.

### The converter

A node in `SemelApple`, `XcodeProjectConverter(path: <X.xcodeproj>, root: <.>,
configuration: 'Debug')`, self-wiring like `SwiftFormulaConverter`: the pbxproj as a
`StaticFile`, the xcconfig files it names as `StaticFile`s (a missing one is empty, and
the `$(VAR)` it would have defined is then reported by `InfoPlistBuilder`), and the
project folder's manifest. No tool runs; the pbxproj is a plist.

Settings resolution, in the order Xcode uses: project xcconfig, project configuration,
target xcconfig, target configuration; `$(inherited)` refers to the level below;
`[sdk=iphonesimulator*]` conditionals apply for the platform the formula builds; `$(VAR)`
references resolve against the resolved set plus the target's own (`TARGET_NAME`,
`PRODUCT_MODULE_NAME`). The formula literal picks the configuration; `Debug` if none.

Per native target the converter emits:
- `include SwiftFormulaConverter(path: <Packages/Timeline>, root: <.>).formula` for each
  local package product the target links, and for each remote one the `Dependencies/<name>`
  folder the vendoring rule puts it in.
- A `SwiftCompiler` over the synchronized folder with `excludedPaths` from the exceptions
  and `moduleTrees` from the linked products; `-parse-as-library`, the deployment target
  and language mode from the settings.
- A `SwiftLinker` with `linkage: 'executable'`, the target's object and every linked
  product's `objects_P()`; an extension gets `-e _NSExtensionMain` and
  `-application_extension` through the linker's `arguments`.
- `AssetCatalogCompiler` over every `.xcassets` and `.icon` in the folder, with
  `ASSETCATALOG_COMPILER_APPICON_NAME`; `StringCatalogCompiler` per `.xcstrings`; plain
  copies of every other resource file, keeping the tree.
- `InfoPlistBuilder` with `INFOPLIST_FILE` as base, actool's partial, and the generated
  keys: `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleName`, `CFBundlePackageType`,
  `CFBundleShortVersionString`, `CFBundleVersion`, `MinimumOSVersion`,
  `CFBundleSupportedPlatforms`, `DTPlatformName`, `UIDeviceFamily`, plus every
  `INFOPLIST_KEY_*` with the prefix stripped (`_Generation` keys becoming the dictionaries
  they stand for), and `PRODUCT_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`, `PRODUCT_MODULE_NAME`,
  `TARGET_NAME` as variables.
- `product '<PRODUCT_NAME>.app/' = TreeMerger(...)` for the application, with each
  extension's tree under `PlugIns/<name>.appex/`; the executable and Info.plist as plain
  products beside them.

Out of scope until IceCubes launches: device signing, app intents metadata
(`appintentsmetadataprocessor`), generated asset and string symbols
(`GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS`, `STRING_CATALOG_GENERATE_SYMBOLS` — the code
does not use them), Mac Catalyst, visionOS.

### Order within part 3

1. Tree inputs: `moduleTrees` on the compiler, `objectTrees` on the linker, and the
   `modules_P` / `objects_P` funcs from the Swift converter; HelloApp rewritten to link a
   package product through them.
2. The converter for the application target alone; IceCubesApp launches without its
   extensions.
3. Extensions under `PlugIns/`.
4. `prepare` on a folder holding an `.xcodeproj`.

## Order

1. Part 1, with `TreeFile` and a `RecordingToolRunner`-level test for output folders.
2. Part 2, verified on `C1/swift/HelloApp` extended with an asset catalog and a string
   catalog, launched in the simulator.
3. Part 3, verified on IceCubesApp.
