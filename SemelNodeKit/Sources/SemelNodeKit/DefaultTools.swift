//
//  DefaultTools.swift
//  SemelNodeKit
//

public class DefaultTools {

    /// The tools this build system knows how to run, by name.  This list is the only
    /// hard-coded part: both the path and the version come from the machine.
    private static let knownToolNames = ["clang", "swiftc", "swift"]

    /// Registers whatever is actually installed.
    ///
    /// Each tool is located with `xcrun --find` and registered under the version it
    /// reports, so a descriptor always describes the binary that will really run.
    ///
    /// Nothing is warned about here.  Installing a newer toolchain is not by itself a
    /// problem, and a node that does not use the changed tool is unaffected — so there is
    /// nothing to say at launch.  A node whose configuration names a version that is no
    /// longer installed fails when it is processed, and `ToolError.noMatchingToolFound`
    /// names both what it asked for and what is available, so the fix is to update that
    /// node's configuration.  Keeping the version in the configuration rather than
    /// following the machine is deliberate: it is what makes a toolchain upgrade
    /// invalidate the cache instead of silently reusing objects built by another compiler.
    public static func setup(toolExecutorRegistry: ToolExecutorRegistry) throws {
        for name in knownToolNames {
            guard let path = AppleClangSwiftToolchainHelper.find(name),
                  let version = AppleClangSwiftToolchainHelper.version(ofToolAt: path) else {
                continue
            }

            toolExecutorRegistry.registerTool(
                descriptor: .init(name: name,
                                  version: version,
                                  platform: "macOS",
                                  architecture: "arm64",
                                  recursiveHash: nil),
                toolExecutor: try LocalFileSystemTool(localPath: path))
        }
    }
}
