//
//  EndToEndRun.swift
//  SemelEndToEndTests
//
//  The harness: one project, materialised under a short root, configured the way a
//  user would, built cold twice in two fresh homes, its products checked and the two
//  export trees compared. A test calls `run()` and gets a pass, or a failure whose
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
        ["semel", "semelserv", "semel-swift"].allSatisfy { FileManager.default.isExecutableFile(atPath: binary($0).path) }
    }

    /// Runs one of the three executables to completion. A non-zero status or the
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
    /// project copies the cached checkout's subfolder parent there. Either way `base` is
    /// what the build folder is relative to.
    func materialise() throws {
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        switch project.source {
        case .fixture:
            try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures, to: tree)
            base = tree
        case .git(let url, let commit, let subfolder):
            let checkout = try CloneCache.checkout(name: project.name, url: url, commit: commit)
            let parent = subfolder == "." ? checkout : checkout.appendingPathComponent(subfolder).deletingLastPathComponent()
            try FileManager.default.copyItem(at: parent, to: tree)
            base = tree
        }
    }

    // MARK: - 2. Configure

    /// The C fixtures get their base config rendered; a project with a platform is
    /// prepared. Once, before both builds, so the two builds see identical inputs.
    func configure() throws {
        let template = base.appendingPathComponent("clang.cfg.template")
        if FileManager.default.fileExists(atPath: template.path) {
            try ClangConfigTemplate.render(template: template, to: base.appendingPathComponent("clang.cfg"))
        }
        if let platform = project.platform {
            try Self.run("semel-swift",
                         arguments: ["prepare", base.appendingPathComponent(project.buildFolder).path, "--platform", platform],
                         timeout: project.buildTimeout, step: "prepare")
        }
    }

    // MARK: - 3 and 5. A cold build

    /// A fresh home named `home`, a server over it, one `semel` session that pushes the
    /// extra folders, builds the build folder and exports into `<root>/<out>`; then the
    /// server stopped cleanly. Returns the export directory.
    func coldBuild(home homeName: String, out outName: String) throws -> URL {
        let server = ServerSession(home: root.appendingPathComponent(homeName, isDirectory: true))
        let out = root.appendingPathComponent(outName, isDirectory: true)
        try server.start()
        do {
            var commands = ["base \(base.path)"]
            commands += project.alsoPush.map { "push \($0)" }
            commands.append("build \(project.buildFolder) --into \(out.path)")
            try Self.run("semel", arguments: commands, environment: server.environment,
                         timeout: project.buildTimeout, step: "build (\(homeName))", serverLog: { server.logTail })
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
        }
        guard problems.isEmpty else {
            let present = (try? FileManager.default.subpathsOfDirectory(atPath: out.path))?.sorted().joined(separator: "\n    ") ?? "(none)"
            throw EndToEndFailure(step: "products (\(out.lastPathComponent))",
                                  message: problems.joined(separator: "; ") + "\n  exported:\n    " + present)
        }
    }

    // MARK: - 6. Determinism

    /// The two export trees must match: the same paths, modes and bytes. This is the
    /// B-04(b) check: two processes, the same inputs, a byte-for-byte diff. A project
    /// marked not deterministic reports the differences as a note instead of failing.
    func checkDeterminism(_ out1: URL, _ out2: URL) throws {
        let differences = try TreeDiff.compare(out1, out2)
        guard !differences.isEmpty else {
            return
        }
        let listed = differences.prefix(20).map(\.description).joined(separator: "\n  ")
        let more = differences.count > 20 ? "\n  … and \(differences.count - 20) more" : ""
        guard project.expectDeterministic else {
            print("\(project.name): \(differences.count) difference(s) between the two builds (not required to match):\n  \(listed)\(more)")
            return
        }
        throw EndToEndFailure(step: "determinism", message: "\(differences.count) difference(s) between out1 and out2:\n  \(listed)\(more)")
    }

    // MARK: - The whole run

    /// Steps 1 to 7. The root is cleaned up on the way out, kept with SEMEL_E2E_KEEP=1.
    func run() throws {
        defer { cleanUp() }
        try materialise()
        try configure()
        let out1 = try coldBuild(home: "home1", out: "out1")
        try checkProducts(in: out1)
        let out2 = try coldBuild(home: "home2", out: "out2")
        try checkProducts(in: out2)
        try checkDeterminism(out1, out2)
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
