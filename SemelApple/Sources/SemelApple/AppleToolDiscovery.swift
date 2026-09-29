//
//  AppleToolDiscovery.swift
//  SemelApple
//
//  Where the resource tools are on this machine and what version they report — what this
//  package declares to `ToolDiscovery` when it registers. They report their versions
//  differently from the compilers: `actool` and `ibtool` answer `--version` with a plist,
//  and `xcstringstool` answers nothing, so a tool with no version of its own is identified
//  by the Xcode that ships it, which is what decides its behaviour. `codesign` answers
//  nothing either and ships with the system, so its binary's own project stamp names it.
//

import Foundation
import SemelNodeKit

enum AppleToolDiscovery {

    /// The tools this package runs, each located through the active toolchain.
    static var finders: [ToolFinder] {
        [
            ToolFinder(name: "actool", locate: { locate("actool") }, version: actoolVersion(at:)),
            ToolFinder(name: "ibtool", locate: { locate("ibtool") }, version: ibtoolVersion(at:)),
            ToolFinder(name: "xcstringstool", locate: { locate("xcstringstool") }, version: { _ in xcodeVersion() }),
            ToolFinder(name: "codesign", locate: { locate("codesign") }, version: codesignVersion(at:)),
        ]
    }

    /// Absolute path to `toolName` in the active toolchain, via `xcrun --find`, or nil if
    /// there is no such tool. Every question this package asks the machine goes through
    /// `MachineQuery`, the one launch-time process runner HermeticityTests allows besides
    /// the sandboxed tool runner.
    static func locate(_ toolName: String) -> String? {
        guard let path = xcrun(["--find", toolName]),
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private static func xcrun(_ arguments: [String]) -> String? {
        MachineQuery.output(of: "/usr/bin/xcrun", arguments)
    }

    // MARK: - actool and ibtool

    /// The version the actool at `path` reports, or nil if it reports nothing recognisable.
    static func actoolVersion(at path: String) -> String? {
        MachineQuery.output(of: path, ["--version"]).flatMap(actoolVersion(fromPlist:))
    }

    /// `actool --version` answers with a plist rather than a line: `com.apple.actool.version`
    /// holding `short-bundle-version` and `bundle-version`.
    static func actoolVersion(fromPlist output: String) -> String? {
        version(ofTool: "actool", fromPlist: output)
    }

    /// The version the ibtool at `path` reports, or nil if it reports nothing recognisable.
    static func ibtoolVersion(at path: String) -> String? {
        MachineQuery.output(of: path, ["--version"]).flatMap(ibtoolVersion(fromPlist:))
    }

    /// `ibtool --version` answers as actool does, under `com.apple.ibtool.version`: both are
    /// launchers of Interface Builder's `ibtoold`, shipped with the Xcode they report.
    static func ibtoolVersion(fromPlist output: String) -> String? {
        version(ofTool: "ibtool", fromPlist: output)
    }

    /// The version under `com.apple.<tool>.version`, rendered like the compilers' strings,
    /// marketing version then build, since the build is what tells two of one version apart.
    private static func version(ofTool tool: String, fromPlist output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["com.apple.\(tool).version"] as? [String: Any],
              let short = version["short-bundle-version"] as? String else {
            return nil
        }
        let build = version["bundle-version"] as? String
        return "Apple \(tool) version \(short)" + (build.map { " (\($0))" } ?? "")
    }

    // MARK: - codesign

    /// The version of the codesign at `path`, from the project stamp its binary carries —
    /// `@(#)PROGRAM:codesign  PROJECT:codesign-83.100.6`, what `what` prints — rendered
    /// `Apple codesign version 83.100.6`. `codesign` has no `--version`, and it ships with
    /// the system rather than with Xcode, so Xcode's version would not say which one runs.
    static func codesignVersion(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return codesignVersion(fromBinary: data)
    }

    static func codesignVersion(fromBinary data: Data) -> String? {
        let marker = Data("PROJECT:codesign-".utf8)
        guard let range = data.range(of: marker) else {
            return nil
        }
        let versionCharacters = Set("0123456789.".utf8)
        let version = data[range.upperBound...].prefix { versionCharacters.contains($0) }
        guard !version.isEmpty else {
            return nil
        }
        return "Apple codesign version " + String(decoding: version, as: UTF8.self)
    }

    // MARK: - Xcode

    /// The Xcode that ships the active toolchain, as `xcodebuild -version` reports it:
    /// `Xcode 26.6 (17F113)`. The version of a tool that has none of its own.
    static func xcodeVersion() -> String? {
        xcrun(["xcodebuild", "-version"]).flatMap(xcodeVersion(from:))
    }

    /// `xcodebuild -version` answers on two lines, `Xcode <version>` then `Build version
    /// <build>`; the build is kept for the same reason the compilers' build identifiers are.
    static func xcodeVersion(from output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let versionLine = lines.first, versionLine.hasPrefix("Xcode ") else {
            return nil
        }
        let build = lines.dropFirst().first?.split(separator: " ").last.map(String.init)
        return versionLine + (build.map { " (\($0))" } ?? "")
    }
}
