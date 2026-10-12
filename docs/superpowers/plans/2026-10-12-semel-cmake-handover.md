# Handover: `semel-cmake` and the `SemelCMake` package (B-157)

Written 2026-10-12 by a cloud session that had no Swift toolchain, for the Mac session
that takes the branch over. Everything below was verified through the repository's own
CI on `macos-26`, never on a Mac by hand. The branch is `claude/ecstatic-babbage-2vg5jt`;
no pull request has been opened for it.

## State of the branch

- Head `5f3b535`, which merges `origin/main` at `0579107` (#196). Three dispatched runs of
  `.github/workflows/swift.yml`:
  - 38179748586 on `2b158e2` (the package and the tool): green, every step.
  - 38182753688 on `c6c9e3f` (the fixture added): red twice on
    `RemovalEndToEndTests.test_removingTheFixtureRunsOnlyTheFinderAndWritesNoEntry`,
    which main fixed as B-156 in #194 after the branch's base; the CMake fixture itself
    passed in both attempts.
  - 38188664167 on `5f3b535` (main merged in): green, every step, the CMake fixture
    through all four hermeticity builds.
- Backlog: the translator is **B-157** (`FUTURE.md`, section "CMake and makefile
  conversion"); main took B-156 for the removal test. Every comment and the fixture say
  B-157. The three earliest commit messages still say B-156, which cannot be changed.
- What a reviewer should know first: `AGENTS.md` and `README.md` already describe the
  tool; `FUTURE.md`'s B-157 entry records the design decision and the "As built" state.

## What was built, and the rules it was built under

The decision, taken with the owner in conversation: translate the rules of a
`CMakeLists.txt` into a formula, do not trace a `cmake` run; refuse the procedural rest
by file and line; an external tool, not a node, because the person edits the formula
afterwards; the stages pure so a node can wrap them later.

`SemelCMake/` is a package depending on `SemelNodeKit` alone, with no file system and no
machine read anywhere in it. The owner asked for "a nice clean model for the parsed
cmake file, then that feeds into the converting thing", which is the layering:

| Stage | File | In | Out |
|---|---|---|---|
| Syntax | `CMakeSyntax.swift` | text | `CMakeFile`: commands with arguments, `${…}` kept as parts, line numbers |
| Evaluation | `CMakeEvaluation.swift`, `CMakeCondition.swift`, `CMakePaths.swift`, `CMakeFacts.swift` | `CMakeFile`, `CMakeFacts`, a reader closure for other files | `CMakeProject` |
| Model | `CMakeProject.swift` | — | targets in CMake's vocabulary, visibility kept, `untranslated` as values |
| Emission | `CMakeFormulaEmitter.swift` | `CMakeProject`, `Build` (target triple, machine-file path) | `semel.fmla` text, `semel.config` text |

Constraints to keep, in order of how much they would cost to lose:

1. No `FileManager`, no `Process`, no `xcrun` inside `SemelCMake`. Files come through
   `CMakeEvaluation.FileReader`; facts come in as `CMakeFacts`. The tool's disk work is
   all in `semel-cmake/Library/CMakeConversion.swift`.
2. No dependency on `SemelCore` or `SemelClang`. The emitter names the clang nodes
   through `derivedSettingNamespace(forTypeName:)`, as the Swift converter does.
3. The model keeps `PUBLIC`/`PRIVATE`/`INTERFACE` as declared; propagation is applied in
   the emitter (`reachedTargets`, `compileRequirements`, `linkRequirements`). What a
   static library links reaches whoever links it, since an archive has no link line.
4. A refusal is a `CMakeUntranslated` value, never an error, and the rest of the project
   is still read. A block whose `if` the facts do not decide is skipped whole.
5. Text that becomes node identity is sorted before it is written (`rendered`,
   `identifiers`, header folders keyed `'00 …'`, `'01 …'` to keep the `-I` order).

The tool: `semel-cmake [<folder>] [--platform …]` writes `semel.fmla` and `semel.config`
once, keeps either that is already there, then writes the clang machine file beside
them through `ClangMachineFile.write` so the formula's `<semel.machine.config>` resolves.

The harness: `Project.converter` names a tool run over the build folder in
`EndToEndRun.configure()`, after the machine file and after `prepare`. The fixture
`EndToEnd/Fixtures/cmake` (`cmake-hello` in `Projects.swift`) commits no formula and no
project config; `.gitignore` keeps a stray in-tree run out; `RosterTests` reads "one
formula per fixture folder" as "none" for a fixture with a converter.

## How to verify on the Mac

```sh
scripts/build.sh test --package-path SemelCMake          # 40 tests: parser, evaluator, emitter
scripts/build.sh                                          # the root package, semel-cmake among it
scripts/build.sh test --filter CMakeConversionTests       # the tool over a folder, the formula parsed by the engine
scripts/build.sh test --filter FixtureTests/test_cmakeHello   # the fixture, four cold builds
swiftlint --strict
```

By hand, which nobody has done yet:

```sh
.build/debug/semel-cmake EndToEnd/Fixtures/cmake          # then read the two files it wrote, and delete them
.build/debug/semel 'base EndToEnd/Fixtures' 'build cmake --into /tmp/cmake-out'
```

The CLI's printed report (`semel-cmake/main.swift`) has never been seen by a person; its
wording is the one place a quick read may want to change something.

## Known limits, each marked in the code

- `ISSUE` in `CMakeSyntax.swift`: `\;` is read as a plain `;` and so splits a list.
- `ISSUE` in `CMakeFormulaEmitter.quoted`: a value holding both quote characters cannot be
  written as a formula string. A define holding a comma splits, as the Swift converter's
  does (`defines` is comma-joined).
- Not translated at all: `configure_file`, `foreach`/`while`/`function`/`macro`,
  `find_package` and every imported target (`Foo::Foo` is refused by name),
  `add_custom_command`, generator expressions, `MODULE`/`OBJECT`/`IMPORTED` libraries,
  `MACOSX_BUNDLE` (built as a plain executable, with a refusal line), `set(… PARENT_SCOPE)`,
  `include(<CMake module>)`, `$ENV{…}`, and the build-tree variables
  (`CMAKE_BINARY_DIR` and kin, `Evaluator.unsupportedVariables`).
- Conditions: `MATCHES`, `EXISTS`, `TARGET`, `COMMAND`, `POLICY` and `VERSION_*` are
  undecidable by design (`CMakeCondition.undecidableTests`).
- Objective-C sources are compiled through the same chain with no `objectiveCARC` or
  `modules` literal; `.s` assembly goes through the preprocessor as C does (the Swift
  converter compiles `.s` directly). Neither has a test.
- A shared library gets no `-install_name`; `ClangLinker` has no setting for it.
- Library link order on the `libraries` port is by wire key, so alphabetical. Apple's
  linker has not minded in the fixture; a project with order-sensitive archives would.
- `CMakeFormulaEmitter.Build.target` comes from `Platform.target(deploymentVersion:)` with
  `CMAKE_OSX_DEPLOYMENT_TARGET` or `14.0`; `--platform ios-simulator` is accepted but
  untested.

## Open decisions, the owner's to make

1. **The makefile side.** The owner asked for "cmake and/or makefiles". The plan agreed in
   conversation: never interpret make's language; evaluate its declarative core
   (variables, `wildcard`, `patsubst`, `filter-out` → `except`, pattern rules → the
   for-each), resolve the rule graph from the goals like a mini-make without running
   anything, classify each recipe line as a compile, an archive or a link and refuse any
   other, and split flags by stage with the same table `compileRequirements` uses. What is
   undecided is whether that translator ends in `CMakeProject` (wrong name, right shape)
   or in a Semel-vocabulary `BuildDescription` that both front ends feed and the emitter
   reads, which would move the propagation step out of the emitter. Do not start the
   make side without that answer.
2. **The node form.** `include CMakeFormulaConverter(path: <.>).formula` would wrap the
   same three stages over a `folderTree` wire and an `IncludableProjectPlugin`
   registration, in `SemelCMake`, with a `kind` from the next free number. Nothing in the
   code needs to change for it; it is a question of whether a project wants the formula
   derived live, which the owner decided against for now.
3. **A real project through the tool.** The roster's `sqlite` and `simdjson` checkouts
   both carry CMake files, and the harness can run a converter over a `.git` source as
   it runs one over a fixture (`configure()` runs it for every source). The first one to
   try will say which refusals matter in practice and which subset additions pay.

## Suggested order of work

1. Run the four commands above on the Mac; nothing is expected to fail.
2. Run `semel-cmake` over one real CMake project and read what it refuses. Extend the
   subset only where a refusal blocks a target, not for completeness.
3. Decide the model question in "Open decisions" with the owner, then the make side.
4. Open the pull request: body with `What`, `Why`, `Testing`, `Checklist`, ending
   with the Claude Code line, per `AGENTS.md`. Delete this file in that PR or keep it as
   the record under `docs/superpowers/plans`, as the owner prefers.

## Things that happened that a successor should not repeat

- Two `spawn_task` hand-off cards may exist on the owner's Mac from this session; the
  tool timed out both times. They described the compile-and-fix loop that CI has since
  done, so they are redundant.
- Dispatching `swift.yml` on the branch is how it was verified
  (`mcp__github__actions_run_trigger`, `run_workflow`); the workflow's concurrency group
  cancels an in-flight run of the same ref, so one dispatch at a time.
- A failure in `RemovalEndToEndTests` that repeats on a re-run is not this branch's; it
  was main's B-156, merged in. Any other red in the root suite is new.
