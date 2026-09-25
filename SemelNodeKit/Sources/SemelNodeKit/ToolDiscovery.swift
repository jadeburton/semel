//
//  ToolDiscovery.swift
//  SemelNodeKit
//
//  Which tools the installed toolchains can find on this machine, and how. A tool
//  descriptor is part of a build's identity — it keys the cache — so the version recorded
//  against a tool has to describe the binary that will actually run. Hard-coding either
//  the path or the version means the build system only works on one machine, and that
//  cached outputs survive a toolchain upgrade they should have been invalidated by.
//
//  Nothing here knows a tool by name. Each toolchain package declares, when it registers
//  its node types, the tools it runs: how to locate each and how it reports its version.
//  The engine then registers whatever those finders actually find.
//

/// One tool a toolchain knows how to find: its registered name, where it is on this
/// machine, and the version the binary there reports.
public struct ToolFinder {
    /// The name a config file's `toolDescriptor.name` gives: `swiftc`, `clang`, `actool`.
    public let name: String
    /// The absolute path of the tool on this machine, or nil if it is not installed.
    public let locate: () -> String?
    /// The version the tool at the path reports, or nil if it reports nothing usable.
    public let version: (String) -> String?

    public init(name: String, locate: @escaping () -> String?, version: @escaping (String) -> String?) {
        self.name    = name
        self.locate  = locate
        self.version = version
    }
}

public enum ToolDiscovery {

    private static var byName: [String: ToolFinder] = [:]

    /// Idempotent per name, because every toolchain's `register()` is.
    public static func register(_ finder: ToolFinder) {
        byName[finder.name] = finder
    }

    /// Every declared finder, alphabetical by name.
    public static var all: [ToolFinder] {
        byName.values.sorted { $0.name < $1.name }
    }

    /// Registers whatever is actually installed: each declared tool that its finder
    /// locates, under the version it reports, so a descriptor always describes the
    /// binary that will really run. A tool that is not installed, or reports no version,
    /// is left out.
    ///
    /// The descriptor also carries a fingerprint of that binary — a hash of its bytes,
    /// `toolBinaryFingerprint(ofFileAt:)` — which is what tells two binaries reporting one
    /// version apart in a cache key. It is taken here rather than declared anywhere: a
    /// config file names a tool by the four identity fields, and which binary answers to
    /// them is a fact about this machine. Reading every installed tool costs a fraction of
    /// a second, once per process, beside the subprocesses this loop already runs.
    ///
    /// Nothing is warned about here. Installing a newer toolchain is not by itself a
    /// problem, and a node that does not use the changed tool is unaffected — so there is
    /// nothing to say at launch. A node whose configuration names a version that is no
    /// longer installed fails when it is processed, and `ToolError.noMatchingToolFound`
    /// names both what it asked for and what is available, so the fix is to update that
    /// node's configuration. Keeping the version in the configuration rather than
    /// following the machine is deliberate: it is what makes a toolchain upgrade
    /// invalidate the cache instead of silently reusing objects built by another compiler.
    public static func registerInstalledTools(into registry: ToolRunnerRegistry) throws {
        for finder in all {
            guard let path = finder.locate(),
                  let version = finder.version(path) else {
                continue
            }

            registry.registerTool(
                descriptor: .init(name: finder.name,
                                  version: version,
                                  platform: MachineQuery.hostPlatform,
                                  architecture: MachineQuery.hostArchitecture,
                                  recursiveHash: toolBinaryFingerprint(ofFileAt: path)),
                toolExecutor: try LocalFileSystemTool(localPath: path))
        }
    }
}
