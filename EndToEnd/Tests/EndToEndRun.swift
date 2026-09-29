//
//  EndToEndRun.swift
//  SemelEndToEndTests
//
//  The harness: one project, materialised under a short root, configured the way a
//  user would, built cold in a fresh home two to four times — a second run, a copy at a
//  second mount, a perturbed environment — its products checked and every export tree
//  compared with the first. A test calls `run()` and gets a pass, or a failure whose
//  message carries the evidence.
//

import Foundation
import SemelTestSupport

final class EndToEndRun {

    let project: Project
    let root: URL
    /// The folder `base` names in the `semel` session: the copy the build folder is
    /// relative to. Set by `materialise`.
    private(set) var base: URL

    init(project: Project) throws {
        self.project = project
        root = try EndToEndEnvironment.newRoot()
        base = root
    }

    // MARK: - The binaries

    static var testBundle: URL { Bundle(for: EndToEndRun.self).bundleURL }

    static func binary(_ name: String) -> URL {
        ProductsDirectory.executable(named: name, besideBundleAt: testBundle)
    }

    static var binariesAreBuilt: Bool {
        ["semel", "semelserv", "semel-swift", "semel-clang"].allSatisfy { FileManager.default.isExecutableFile(atPath: binary($0).path) }
    }

    /// Runs one of the executables to completion. A non-zero status or the
    /// deadline is a failure naming `step`, with the command and the output's tail.
    @discardableResult
    static func run(_ tool: String, arguments: [String], environment: [String: String] = [:],
                    currentDirectory: URL? = nil, timeout: TimeInterval, step: String,
                    serverLog: (() -> String)? = nil) throws -> ManagedProcess {
        let process = ManagedProcess(executable: binary(tool), arguments: arguments,
                                     environment: environment, currentDirectory: currentDirectory)
        try process.start()
        guard let status = process.waitForExit(timeout: timeout) else {
            process.kill()
            _ = process.waitForExit(timeout: 10)
            throw EndToEndFailure(step: step, message: "timed out after \(Int(timeout)) s", commandLine: process.commandLine,
                                  outputTail: process.outputTail(), serverLogTail: serverLog?())
        }
        guard status == 0 else {
            throw EndToEndFailure(step: step, message: "exit status \(status)", commandLine: process.commandLine,
                                  status: status, outputTail: process.outputTail(), serverLogTail: serverLog?())
        }
        return process
    }

    // MARK: - 1. Materialise

    /// A fixture project copies the whole `Fixtures` tree to `<root>/tree`; an external
    /// project copies the cached checkout's subfolder parent there, except that a
    /// subfolder of `"."` nests the checkout one level under `tree`, named after the
    /// project, instead of copying it to `tree` directly — `build`'s folder argument
    /// cannot be the base itself (`push .` resolves to nothing to push), so a project
    /// whose build folder is the checkout's own root needs a real subfolder to name; its
    /// `buildFolder` is then `project.name`. Either way `base` is what the build folder
    /// is relative to. A `.git` source with an overlay then gets the overlay laid over the
    /// subfolder's copy (B-76) — here, before `configure`, so that `prepare` runs over the
    /// corrected tree, and every build, the second mount's copy included, sees it.
    func materialise() throws {
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        switch project.source {
        case .fixture:
            try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures, to: tree)
        case .git(let url, let commit, let subfolder, let overlay):
            let checkout = try CloneCache.checkout(name: project.name, url: url, commit: commit)
            let copiedSubfolder: URL
            if subfolder == "." {
                try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
                copiedSubfolder = tree.appendingPathComponent(project.name, isDirectory: true)
                try FileManager.default.copyItem(at: checkout, to: copiedSubfolder)
            } else {
                let parent = checkout.appendingPathComponent(subfolder).deletingLastPathComponent()
                try FileManager.default.copyItem(at: parent, to: tree)
                copiedSubfolder = tree.appendingPathComponent(URL(fileURLWithPath: subfolder).lastPathComponent, isDirectory: true)
            }
            if let overlay {
                try Self.lay(overlay:       EndToEndEnvironment.fixtures.appendingPathComponent(overlay, isDirectory: true),
                             over:          copiedSubfolder,
                             replacingOnly: project.platform != nil)
            }
        case .repository:
            try Self.copyRepository(to: tree.appendingPathComponent(project.name, isDirectory: true))
        }
        base = tree
        try project.materialised?(tree.appendingPathComponent(project.buildFolder, isDirectory: true))
    }

    /// The entry at an overlay's root that is the overlay's own and is not laid: the note
    /// saying where its files come from and what was changed in them. Laid, it would
    /// replace the checkout's `README.md`, which a project file may list.
    static let overlayNoteName = "README.md"

    /// Lays `overlay` over `folder`, file by file: a file replaces the file at its path, and
    /// a folder merges into the checkout's folder of its name rather than replacing it, so
    /// `App/Orders/OrderDetailView.swift` corrects that one file and leaves the rest of `App`
    /// as the checkout has it. The two kinds of overlay need both: the formula and config a
    /// C project lacks sit at the root, while a correction to a sample's sources sits deep in
    /// its tree (B-77). `replacingOnly` is for the second kind: every file must replace one
    /// the checkout has, because a path that has drifted would otherwise add a file nothing
    /// compiles and leave the uncorrected one in the build, failing far from the cause.
    static func lay(overlay: URL, over folder: URL, replacingOnly: Bool) throws {
        try merge(overlay, into: folder, replacingOnly: replacingOnly, skipping: [overlayNoteName])
    }

    private static func merge(_ source: URL, into folder: URL, replacingOnly: Bool, skipping skipped: Set<String>) throws {
        let fileManager = FileManager.default
        for name in try fileManager.contentsOfDirectory(atPath: source.path).sorted() where name != ".DS_Store" && !skipped.contains(name) {
            let entry  = source.appendingPathComponent(name)
            let target = folder.appendingPathComponent(name)
            var entryIsFolder:  ObjCBool = false
            var targetIsFolder: ObjCBool = false
            _ = fileManager.fileExists(atPath: entry.path, isDirectory: &entryIsFolder)
            let targetExists = fileManager.fileExists(atPath: target.path, isDirectory: &targetIsFolder)
            if entryIsFolder.boolValue && targetIsFolder.boolValue {
                try merge(entry, into: target, replacingOnly: replacingOnly, skipping: [])
                continue
            }
            guard targetExists || !replacingOnly else {
                throw EndToEndFailure(step: "materialise",
                                      message: "the overlay's \(entry.path) replaces nothing: \(target.path) is not in the checkout")
            }
            if targetExists {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: entry, to: target)
        }
    }

    /// Names left out of the repository's copy wherever they occur: build products of
    /// this package and of every nested one, version control and editor state, the export
    /// folder a `build` without `--into` writes, and the two things an in-place `prepare`
    /// leaves — a machine file and vendored dependencies — which the run's own `prepare`
    /// writes afresh.
    static let repositoryCopyExcludedNames: Set<String> = [
        ".build", ".git", ".swiftpm", ".claude", ".idea", ".DS_Store", "DerivedData",
        "semel-out", "Dependencies", machineFileName,
    ]

    /// Paths left out of the copy, relative to the repository root: the fixtures are
    /// projects of their own, each with a formula the project finder would build and a
    /// machine file only their own runs write.
    static let repositoryCopyExcludedPaths: Set<String> = ["EndToEnd/Fixtures"]

    /// The checkout, less what `repositoryCopyExcludedNames` and `…Paths` name, under
    /// `destination`. A copy by hand rather than `copyItem`, which takes all or nothing.
    static func copyRepository(to destination: URL) throws {
        let root = EndToEndEnvironment.repositoryRoot
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: []) else {
            throw EndToEndFailure(step: "materialise", message: "cannot list \(root.path)")
        }
        for case let url as URL in enumerator {
            let relative    = String(url.path.dropFirst(root.path.count + 1))
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            if repositoryCopyExcludedNames.contains(url.lastPathComponent) || repositoryCopyExcludedPaths.contains(relative) {
                // Only for a folder: asked after a file, `skipDescendants` skips the rest
                // of that file's folder, which is how one `.DS_Store` once emptied a
                // package of its manifest.
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            let target = destination.appendingPathComponent(relative)
            if isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.copyItem(at: url, to: target)
            }
        }
    }

    // MARK: - 2. Configure

    /// The machine's half of the C fixtures' settings is written beside them (B-109), and
    /// beside a checkout overlaid with a formula, which reads it the same way (B-76); a
    /// project with a platform is prepared, which writes its own — an overlaid one too,
    /// whose overlay corrects sources and carries no formula. Once, before both builds, so
    /// the two builds see identical inputs.
    func configure() throws {
        switch project.source {
        case .fixture, .git(_, _, _, .some) where project.platform == nil:
            try writeMachineFile(to: base.appendingPathComponent(Self.machineFileName))
        case .git, .repository:
            break
        }
        if let platform = project.platform {
            try Self.run("semel-swift",
                         arguments: ["prepare", base.appendingPathComponent(project.buildFolder).path, "--platform", platform],
                         timeout: project.buildTimeout, step: "prepare")
        }
    }

    static let machineFileName = "semel.machine.config"

    /// The file the C fixtures read as `../semel.machine.config`, written the way a user
    /// writes it: `semel-clang` on the folder the formula looks in, outside Semel (B-119).
    /// The loop a user goes through when it is missing — build, write, build — is
    /// `AutostartTests`' to prove.
    private func writeMachineFile(to file: URL) throws {
        try Self.run("semel-clang", arguments: [file.deletingLastPathComponent().path],
                     timeout: 60, step: "semel-clang")
    }

    // MARK: - 3, 5, 6b and 6c. A cold build

    /// A fresh home named `home`, a server over it, one `semel` session that pushes the
    /// extra folders, builds the build folder and exports into `<root>/<out>`; then the
    /// server stopped cleanly. `base` is the copy to build, the run's own unless a caller
    /// materialised another; a `perturbation` varies what both processes are told about
    /// their surroundings. Returns the export directory.
    func coldBuild(base buildBase: URL? = nil, home homeName: String, out outName: String,
                   perturbation: Perturbation? = nil) throws -> URL {
        let buildBase = buildBase ?? base
        let server = ServerSession(home: root.appendingPathComponent(homeName, isDirectory: true),
                                   perturbation: perturbation)
        let out = root.appendingPathComponent(outName, isDirectory: true)
        try server.start()
        do {
            var commands = ["base \(buildBase.path)"]
            commands.append("build \(project.buildFolder) --into \(out.path)")
            // The graph's own invariants, asked of it after every build in the roster, so
            // that the fixtures are what proves them: a wire into a node that is gone, a
            // manifest naming a child that is not there, a product nothing produces. Each
            // finding counts as an error at the prompt, so a broken invariant leaves the
            // session non-zero and the failure below carries the findings in its tail.
            commands.append("check")
            try Self.run("semel", arguments: commands, environment: server.environment,
                         currentDirectory: perturbation?.workingDirectory,
                         timeout: project.buildTimeout, step: "build and check (\(homeName))",
                         serverLog: { server.logTail })
        } catch {
            server.killIfRunning()
            throw error
        }
        try server.stop()
        return out
    }

    // MARK: - 4. Products

    /// Every expected product exists under `out` and is not empty. Listed one by one, so
    /// a missing icon is a named failure.
    func checkProducts(in out: URL) throws {
        var problems: [String] = []
        for product in project.expectedProducts {
            let url = out.appendingPathComponent(product)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                problems.append("missing: \(product)")
                continue
            }
            if (attributes[.size] as? UInt64 ?? 0) == 0 {
                problems.append("empty: \(product)")
            }
            let mode = (attributes[.posixPermissions] as? Int ?? 0) & 0o777
            if project.executables.contains(product), mode != 0o755 {
                problems.append("not executable: \(product) (\(String(mode, radix: 8)))")
            }
        }
        if let folder = project.onlyUnder {
            for path in try TreeDiff.relativePaths(under: out) where !path.hasPrefix(folder + "/") {
                problems.append("outside \(folder): \(path)")
            }
        }
        guard problems.isEmpty else {
            let present = (try? FileManager.default.subpathsOfDirectory(atPath: out.path))?.sorted().joined(separator: "\n    ") ?? "(none)"
            throw EndToEndFailure(step: "products (\(out.lastPathComponent))",
                                  message: problems.joined(separator: "; ") + "\n  exported:\n    " + present)
        }
        try project.exported?(out)
    }

    // MARK: - 6. Determinism

    /// The two export trees must match: the same paths, modes and bytes, except the paths
    /// `project.mayDiffer` names. This is the B-04(b) check: two processes, the same
    /// inputs, a byte-for-byte diff. A difference the roster exempts is printed as a note;
    /// every other difference fails the run.
    func checkDeterminism(_ out1: URL, _ out2: URL) throws {
        let differences = try TreeDiff.compare(out1, out2)
        guard !differences.isEmpty else {
            return
        }
        let exempt = differences.filter { Self.exempt($0, by: project.mayDiffer) }
        let notExempt = differences.filter { !Self.exempt($0, by: project.mayDiffer) }
        if !exempt.isEmpty {
            print("\(project.name): \(exempt.count) difference(s) between the two builds, exempt by the roster:\n  \(Self.listed(exempt))")
        }
        guard !notExempt.isEmpty else {
            return
        }
        throw EndToEndFailure(step: "determinism",
                              message: "\(notExempt.count) difference(s) between out1 and out2:\n  \(Self.listed(notExempt))")
    }

    /// Two export trees that must match, except where `mayDiffer` exempts a path: what a
    /// second mount and a perturbed environment both ask for. `step` names the check and
    /// `subject` says which trees and what was varied between them.
    private func requireMatch(_ out: URL, _ other: URL, step: String, subject: String) throws {
        let notExempt = try TreeDiff.compare(out, other).filter { !Self.exempt($0, by: project.mayDiffer) }
        guard !notExempt.isEmpty else {
            return
        }
        throw EndToEndFailure(step: step,
                              message: "\(notExempt.count) difference(s) \(subject):\n  \(Self.listed(notExempt))")
    }

    /// The differences a failure message carries: the first twenty, then a count of the
    /// rest, so a tree that differs everywhere stays readable.
    private static func listed(_ differences: [TreeDiff.Difference]) -> String {
        let shown = differences.prefix(20).map(\.description).joined(separator: "\n  ")
        return differences.count > 20 ? shown + "\n  … and \(differences.count - 20) more" : shown
    }

    /// Whether `mayDiffer` names `difference.path`, exactly or as a trailing path: a
    /// component boundary is required, so `Assets.car` names only paths ending
    /// `/Assets.car`, not an unrelated file that merely ends with the same characters.
    static func exempt(_ difference: TreeDiff.Difference, by mayDiffer: [String]) -> Bool {
        mayDiffer.contains { difference.path == $0 || difference.path.hasSuffix("/" + $0) }
    }

    // MARK: - 6b. A second mount

    /// The prepared copy again, beside the first under a folder whose name has a
    /// different length, so a path a tool embedded would show up as a size difference
    /// even if the diff's content check were fooled. Prepare is not run again: the copy
    /// already carries what prepare wrote, so the third build sees the first's inputs at
    /// a different place and nothing else.
    func materialiseSecondMount() throws -> URL {
        let mount = root.appendingPathComponent("mount-b-longer-name", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let copy = mount.appendingPathComponent(base.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: base, to: copy)
        return copy
    }

    /// Build three must match build one the way build two did. The roster's exemptions
    /// apply here too: an archive's timestamp is no more a mount than it is a run.
    func checkMountIndependence(_ out1: URL, _ out3: URL) throws {
        try requireMatch(out1, out3, step: "two mounts", subject: "between out1 and out3 (the second mount)")
    }

    // MARK: - 6c. A perturbed environment

    /// Build four must match build one although it was told a different temporary
    /// directory, locale, time zone and working directory — B-05. None of that is in a
    /// cache key, so a difference is a build that read its surroundings: a sandbox path
    /// in an output, a locale-sorted list, a rendered date. The roster's exemptions apply,
    /// because a file that is not reproducible between two runs is not reproducible here
    /// either; the failure names the perturbation, so the message says what to vary by
    /// hand to see it again.
    func checkPerturbationIndependence(_ out1: URL, _ out4: URL, _ perturbation: Perturbation) throws {
        try requireMatch(out1, out4, step: "perturbed environment",
                         subject: "between out1 and out4, built with \(perturbation.description)")
    }

    // MARK: - The whole run

    /// Steps 1 to 7, with the second mount and the perturbed build between the
    /// determinism check and clean-up.
    func run() throws {
        defer { cleanUp() }
        try materialise()
        try configure()
        let out1 = try coldBuild(home: "home1", out: "out1")
        try checkProducts(in: out1)
        let out2 = try coldBuild(home: "home2", out: "out2")
        try checkProducts(in: out2)
        try checkDeterminism(out1, out2)
        if project.twoMounts {
            let second = try materialiseSecondMount()
            let out3 = try coldBuild(base: second, home: "home3", out: "out3")
            try checkProducts(in: out3)
            try checkMountIndependence(out1, out3)
        }
        if project.perturbed {
            let perturbation = try Perturbation.under(root: root)
            let out4 = try coldBuild(home: "home4", out: "out4", perturbation: perturbation)
            try checkProducts(in: out4)
            try checkPerturbationIndependence(out1, out4, perturbation)
        }
    }

    // MARK: - 7. Clean up

    func cleanUp() {
        if EndToEndEnvironment.keepsRoots {
            print("SEMEL_E2E_KEEP=1: kept \(root.path)")
        } else {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
