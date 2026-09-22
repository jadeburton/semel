# End-to-end testing: real projects through both binaries

**Status:** implemented; see `docs/superpowers/plans/2026-09-17-semel-end-to-end-testing.md`
for what differed from this text.

- `SemelServTests` is `SemelServerTests`.
- `swift-hello-app` does not skip.
- `swift-my-app` pushes `swift/MyLibrary` first and the two C fixtures push `clang.cfg`
  first (`Project.alsoPush`).
- `prepare` writes the namespaces a kept formula selects.
- `TreeDiff` resolves the root through `realpath` because `/tmp` is a symlink on macOS.
- `Project.mayDiffer` is empty for every roster entry except `icecubes-app`: `SwiftLinker`
  makes `.staticArchive` output deterministic (B-72), so the two export trees match byte for
  byte with no exemptions elsewhere. `icecubes-app` names five paths the Apple toolchain
  itself does not reproduce byte for byte — `actool`'s `.icon` renditions (B-89) and the
  linker's duplicate `_objc_msgSend` GOT entry (B-90) — until one of those items closes.

## 1. Why

Semel's six unit suites test the engine, the toolchains, the protocol and the two halves
of the daemon in isolation. Nothing in the repository builds a real project through
`semelserv` and `semel` together. The projects that do get built that way live in `C1`, a
folder outside the repository and outside git, run by hand from a recipe that exists only
in notes. A build that works there proves something once, on one machine.

The ultimate proof that the system works is a real-world project, prepared and built the
way a user would do it, with the products checked and the build shown to be repeatable.
This design makes that proof a test: contained, so a fresh checkout can run it; repeatable,
so it runs the same on every machine and in CI; and the home for the determinism and
perturbation checks the backlog wants (B-04, B-05).

Two tiers, one harness:

- **Fixtures.** Small home-made projects committed into the repository, one per toolchain
  shape. They run on every `swift test` and on every PR. They are a bridge: as real
  projects of each shape are pinned, fixtures can go.
- **External projects.** Real projects pinned by repository and commit, fetched on demand,
  run only on opt-in and nightly in CI. IceCubesApp is the first.

## 2. Layout

Everything lives under a new `EndToEnd/` folder at the repository root.

```
EndToEnd/
  Fixtures/
    clang.cfg.template      # base clang config, two placeholders (Section 4)
    c/                      # hello: hello, hello.dylib, config.txt
    cpp/                    # emu6502, a C++ project with its own clang.cfg overlay
    swift/
      HelloApp/             # hand-written formula: a SwiftUI app bundle for the simulator
      MyApp/                # a package with a path dependency on MyLibrary
      MyLibrary/
  Tests/                    # the SemelEndToEndTests target
    Project.swift
    Projects.swift
    EndToEndRun.swift
    FixtureTests.swift
    ExternalProjectTests.swift
```

The fixtures are copied from `C1` with build output and dependency checkouts stripped.
`C1/swift/build_system`, a copy of Semel itself, stays out. The C and C++ formulas keep
their `<../clang.cfg>` reference, so a fixture run's base is the `Fixtures` copy and its
build folder is `c`, `cpp` or `swift/HelloApp`; the tree keeps the `C1` shape.

**No fixture commits a `semel.config`, and the C fixtures commit a template, not a
`clang.cfg`.** Both files carry values from the machine that wrote them, the SDK version and
path and the tool version string, and the toolchains verify those against what is
installed. Section 4 says how each is produced at run time.

`SemelEndToEndTests` is a test target of the root package with `path: "EndToEnd/Tests"`.
It depends on the three executable targets, `semel`, `semel-server` and `semel-swift`, the
way `SemelServTests` depends on `semel-server`, so `swift test` builds the binaries beside
the test bundle and the harness finds them in the products directory.

`C1` is not read by anything in the repository. It remains a scratch area.

## 3. The roster

`Project.swift` defines one value type:

```swift
struct Project {
    enum Source {
        case fixture(folder: String)                              // relative to Fixtures/
        case git(url: String, commit: String, subfolder: String)  // subfolder may be "."
    }
    let name: String
    let source: Source
    let buildFolder: String        // the argument to `build`, relative to the base
    let platform: String?          // for `semel-swift prepare --platform`; nil = no prepare
    let expectedProducts: [String] // relative to the export directory; every one must exist
    let buildTimeout: TimeInterval
}
```

`Projects.swift` is the roster, one value per project. Adding a project is adding a value.

| Name | Source | Build folder | Platform | Expected products |
|---|---|---|---|---|
| `c-hello` | fixture `.` | `c` | none | `hello`, `hello.dylib`, `config.txt` |
| `cpp-emu6502` | fixture `.` | `cpp` | none | `emu6502` |
| `swift-my-app` | fixture `.` | `swift/MyApp` | `macos` | the converter's products; confirmed when the roster is written |
| `swift-hello-app` | fixture `.` | `swift/HelloApp` | `ios-simulator` | `Hello.app/Hello`, `Hello.app/Info.plist`, `Hello.app/PkgInfo`, `Hello.app/Assets.car` |
| `icecubes` | git `https://github.com/Dimillian/IceCubesApp.git` at `3dc60a80a66db2c3a92c517b38398246ef4ea1b9`, subfolder `Packages` | `Packages` | `ios-simulator` | `libConversations.a`, `libExplore.a`, `libLists.a`, `libNotifications.a`, `libTimeline.a` |
| `icecubes-app` | git `https://github.com/Dimillian/IceCubesApp.git` at `3dc60a80a66db2c3a92c517b38398246ef4ea1b9`, subfolder `.` | `icecubes-app` | `ios-simulator` | `Ice Cubes.app/Ice Cubes`, `Ice Cubes.app/Info.plist`, `Ice Cubes.app/Assets.car`, and each of the four `.appex` bundles' executables under `PlugIns/` |

The base of a fixture run is the `Fixtures` copy; for `c-hello` the base is the copy and
the build folder `c`. The base of an external run is the copy of the subfolder's parent,
so IceCubes builds `Packages` with `Dependencies` beside it, as `C1/icecubes` does. A
subfolder of `.` names the checkout's own root as what the build folder builds; since
`build`'s folder argument cannot be the base itself, the checkout is nested one level under
base instead, named after the project — `icecubes-app`'s build folder is `icecubes-app`.

The IceCubes formula is what `prepare` writes: one `package(p)` function over the
converter and five `include`s, the consumption roots, for `icecubes`; for `icecubes-app`,
`XcodeProjectConverter`'s formula for the application target and its four embedded
extensions. Nothing hand-written is needed for either.

`swift-hello-app` depends on the `SemelApple` nodes (B-64) being on `main`; until then
that fixture is listed in the roster and its test skips with a message naming B-64.

Timeouts: two minutes for a fixture, fifteen for each of `icecubes` and `icecubes-app`.

## 4. What one run does

`EndToEndRun.swift` is the harness. A test calls it once with a `Project` and gets a pass
or a failure whose message carries the evidence.

1. **Materialise.** Create a short root under `/tmp/semel-tests/<8 hex>/`; sockets live
   under it and a Unix-domain socket path is limited to 103 bytes. A fixture project copies
   the whole `Fixtures` tree there. An external project is fetched into the cache once,
   keyed `<name>-<commit>`, as a checkout of that one commit (`git init`, `git fetch
   --depth 1 <url> <commit>`, `git checkout FETCH_HEAD`), then copied to the root. The
   cache holds the raw checkout only; nothing is ever built in it.
2. **Configure.** For the C fixtures, `clang.cfg.template` is rendered to `clang.cfg` in
   the copy: `${CLANG_VERSION}` from `clang --version`'s first line and `${MACOS_SDK_PATH}`
   from `xcrun --sdk macosx --show-sdk-path`. For a project with a platform, `semel-swift
   prepare <buildFolder> --platform <platform>` runs in the copy and writes `semel.config`
   (and the formula, where none is committed). Vendoring fetches dependencies here, so an
   external run needs the network. Prepare runs once per test, before both builds, so the
   two builds see identical inputs.
3. **Cold build one.** A fresh home `home1` under the root. `semelserv` is started with
   `SEMEL_HOME` and `SEMEL_SOCKET` pointing into it and the socket is waited for. Then
   `semel 'base <copy base>' 'build <buildFolder> --into <root>/out1'`. The exit status must
   be zero. The server is sent `SIGTERM`, must exit zero, and its socket file must be gone.
4. **Products.** Every expected product exists under `out1` and is not empty. A bundle's
   entries are listed one by one, so a missing icon is a named failure.
5. **Cold build two.** The same copy, a fresh `home2`, exported to `out2`. Nothing from
   build one survives except the source tree.
6. **Determinism.** `out1` and `out2` must match: the same set of relative paths, the same
   modes, byte-identical contents. The failure names the first differing paths and how
   they differ (missing, mode, size, first differing offset), so a timestamp or an embedded
   path is recognisable from the message. This closes B-04(b).
7. **Clean up.** The root is removed. With `SEMEL_E2E_KEEP=1` it is kept and its path
   printed.

**Failure evidence.** Every subprocess's stdout and stderr are captured. A failed step's
message includes the command line, the exit status, and the last lines of its output and
of the server's log, so a CI failure reads without a rerun.

**Timeouts.** A build that exceeds the project's timeout has both processes killed and the
test fails naming the step.

**Shared code.** The subprocess launch with the two environment variables, the socket wait
and the products-directory lookup exist in `SemelservExecutableTests`. They move into a
small helper the server tests and this target both use, rather than being copied.

## 5. Opt-in, cache, CI

Three environment variables, read only by the end-to-end target. The hermeticity scan
covers node-side packages; this target is not one.

- `SEMEL_E2E_EXTERNAL=1` runs the external projects. Without it, those tests report as
  skipped, so a plain `swift test` is fast and offline.
- `SEMEL_E2E_CACHE` overrides the clone cache; default `~/Library/Caches/semel/end-to-end/`.
- `SEMEL_E2E_KEEP=1` keeps a run's root directory.

**Pull requests.** The existing workflow's root `swift test` step now includes the fixture
tests, so every PR builds the C, C++ and Swift fixtures through both binaries.

**Nightly.** A second workflow, `.github/workflows/end-to-end.yml`: on a nightly schedule
for `main` and on manual dispatch; a macOS runner; select Xcode; `swift build`; then
`SEMEL_E2E_EXTERNAL=1 swift test --filter SemelEndToEndTests`. The clone cache is restored
and saved with the actions cache, keyed on the pinned commits, so IceCubes is fetched once
per pin change. Because `prepare` and the template take SDK and tool versions from the
machine that runs them, the runner's Xcode and a developer's both work without edits.

## 6. Documentation

- AGENTS.md: the build-and-test block gains the target with its opt-in line, and the
  composition-root paragraph names the harness as the way both binaries are run together.
- README: a short "Testing against real projects" paragraph.
- BACKLOG: B-04(b) closed by Section 4 step 6; B-05 points at the harness as its home.

## 7. Later, not now

- A warm third build in `home1`, to show the second run is cache hits. Needs a way to
  observe hits from the client; B-11 territory.
- B-05 perturbations: extra builds with a different `TMPDIR`, cwd or locale and the same
  diff.
- More external projects, one per shape: a macOS command-line package, an `.xcodeproj`
  once B-65 lands. Each is one roster value.
- Retiring fixtures as real projects cover their shape.
