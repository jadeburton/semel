# Continuous integration

The two workflows run on two kinds of runner. `.github/workflows/swift.yml`, on every push
and pull request, runs on GitHub's hosted `macos-26` image: a pull request's code is a
stranger's code on a public repository, and a hosted runner is where that may run. The
image carries Xcode 26.6 and Swift 6.3.3, the toolchain the project is developed against,
and hosted runners are free for a public repository — while the repository was private
they billed ten minutes of quota per minute run, which is why the workflow began on a
self-hosted runner, and an earlier hosted image's Xcode lacked what actool needed, which
left main red for five days before anyone read the cause. `hosted-runner-trial.yml`, run by
hand, is how a new image is checked before the workflow moves to it: it prints what the
image carries and runs the build and two suites.

`.github/workflows/end-to-end.yml`, nightly, runs on a self-hosted macOS runner: a Mac
that belongs to the project, registered with the repository. It clones and builds real
projects for a quarter of an hour, which is the project's own code and its pinned
dependencies, never a pull request's; it runs on schedule and dispatch only, which a fork
cannot trigger. Two settings stand behind that anyway: the repository's Actions settings
require approval for every outside collaborator's workflow run before it starts, and the
workflows pin the actions they use by commit SHA, which the repository requires, with
Dependabot keeping the pins current.

## What the runner needs

- Xcode selected (`xcode-select -p`), with the iOS simulator runtime for that Xcode's SDK
  installed: `xcrun simctl list runtimes` lists it. The fixtures build a simulator app.
- SwiftLint on the machine: `brew install swiftlint`. The lint job looks for it on `PATH`
  and falls back to `/opt/homebrew/bin/swiftlint`, because a runner installed as a service
  does not read a shell profile.
- Disk: a checkout plus `.build` is a few gigabytes; the nightly's kept run roots are a few
  more each and are removed at the end of the job.
- Network for the nightly's clones; the fixture suite needs none.

## Registering the runner

1. On GitHub: repository → Settings → Actions → Runners → New self-hosted runner → macOS,
   ARM64. The page shows a download command and a `./config.sh --url … --token …`
   command; the token is short-lived and personal, so this step is done by hand.
2. In a folder that will stay, for example `~/actions-runner`:

   ```
   ./config.sh --url https://github.com/<owner>/semel --token <token> --labels macOS
   ```

   Accept the default runner name and work folder. The `macOS` label is what both
   workflows' `runs-on: [self-hosted, macOS]` select; `self-hosted` is added by GitHub.
3. Run it as a service so it survives logouts and restarts:

   ```
   ./svc.sh install
   ./svc.sh start
   ```

   `./svc.sh status` shows whether it is listening; the Runners page shows it as Idle.

A job runs only while the machine is awake. A laptop lid closed mid-run leaves the run
queued until the lid opens; the concurrency groups in the workflows cancel a superseded
pull-request run, so a backlog of stale runs does not form.

## What the workflows do to stay cheap

- Every push and pull request runs, documentation included. It did not always: a
  `paths-ignore` for `docs/**` and Markdown once saved a third of a week's runs, and went
  when the `main` ruleset began requiring `build-and-test` and `lint` to pass — a check
  that never reports on a docs-only change leaves that change unmergeable by anyone
  without bypass.
- A newer push to a pull request's branch cancels the run in flight (`concurrency` with
  `cancel-in-progress`, which is off for `main`): only the newest head can be merged, so
  the older verdict is worth nothing. A run on `main` is never cancelled — every merged
  commit gets a verdict of its own, where a cancelled one left a commit with none and a
  mark that reads as a failure in the commit list — and the nightly never cancels itself.
- Each run starts from a clean checkout. `.build` is not carried between runs on purpose:
  a stale plan there produces the failures AGENTS.md's build notes describe, and a clean
  release build on Apple silicon is a few minutes.

## Reading a failure

The `Toolchain` step prints the Xcode, Swift and simulator runtimes the run used; read it
first when a failure looks environmental. The nightly uploads `/tmp/semel-tests` as an
artifact on failure, which holds every export tree the project built and the server home
behind each: two for an external project, four for a fixture — the second run, the copy at
a second mount and the perturbed environment each add one.
