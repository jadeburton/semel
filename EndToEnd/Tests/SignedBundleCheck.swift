//
//  SignedBundleCheck.swift
//  SemelEndToEndTests
//
//  What a list of products cannot say about a Mac bundle Semel signed (B-77): that the
//  exported bundle verifies as the whole it is, and that its executable carries the
//  bundle's signature — sealed resources, the entitlements — not only the ad-hoc one the
//  linker writes.
//

import Foundation

enum SignedBundleCheck {

    /// `codesign --verify --deep --strict` on `bundle` in the export: every nested bundle
    /// and the bundle itself hold, with nothing added, missing or changed. Then the
    /// executable at `executable` is signed ad-hoc as part of the bundle, and, when
    /// `entitlement` is given, the bundle's signature carries it.
    static func verifying(bundle: String, executable: String, entitlement: String? = nil) -> (URL) throws -> Void {
        { out in
            let bundleURL = out.appendingPathComponent(bundle)
            try verified(bundleURL)
            try signedAsPartOfTheBundle(out.appendingPathComponent(executable))
            if let entitlement {
                let entitlements = try run(["-d", "--entitlements", ":-", bundleURL.path], step: "codesign -d --entitlements")
                guard entitlements.contains(entitlement) else {
                    throw EndToEndFailure(step: "codesign -d --entitlements", message: "\(bundle) is not signed with \(entitlement):\n\(entitlements)")
                }
            }
        }
    }

    static func verified(_ bundle: URL) throws {
        try run(["--verify", "--deep", "--strict", "--verbose=2", bundle.path], step: "codesign --verify")
    }

    /// The executable's signature is the bundle's: ad-hoc, bound to the Info.plist and
    /// sealing the resources. The linker's own ad-hoc signature is neither.
    static func signedAsPartOfTheBundle(_ executable: URL) throws {
        let details = try run(["-dv", executable.path], step: "codesign -dv")
        for expected in ["Signature=adhoc", "Sealed Resources version=2"] where !details.contains(expected) {
            throw EndToEndFailure(step: "codesign -dv", message: "\(executable.lastPathComponent) has no \(expected):\n\(details)")
        }
        guard !details.contains("Info.plist=not bound") else {
            throw EndToEndFailure(step: "codesign -dv", message: "\(executable.lastPathComponent)'s signature binds no Info.plist:\n\(details)")
        }
    }

    /// Runs `codesign` to completion, returning what it printed on either stream; a
    /// non-zero status is a failure naming the step.
    @discardableResult
    private static func run(_ arguments: [String], step: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw EndToEndFailure(step: step, message: "codesign \(arguments.joined(separator: " ")) exited \(process.terminationStatus):\n\(text)")
        }
        return text
    }
}
