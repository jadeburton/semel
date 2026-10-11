// HostOperatingSystem.swift
// SemelNodeKit
//
// The operating system's build, as a machine fact a tool's output can depend on (B-153's
// audit). Most tools are what their binary's bytes say they are, and the binary's fingerprint
// covers them (B-17). Some do their work through the system's own frameworks instead:
// actool writes `Assets.car` through CoreUI, ibtool archives nibs through AppKit, momc
// archives a model through Core Data, xcstringstool reads a catalog through Foundation, and
// codesign signs through the Security framework. None of those is a byte of the tool, and an
// update of macOS changes them under a tool whose version and fingerprint stay as they were —
// so two machines on two builds of macOS, with one Xcode, would share an entry each wrote
// differently. A node whose tool works through the system folds the build into its key.
//
// Declared twice, as every machine fact is (AGENTS.md): material in the key, which stops a
// wrong reuse between machines, and a machine setting, `hostOSBuild`, under each such tool's
// namespace, which wakes the nodes when the machine file is written again after an update.

import Darwin
import Foundation

public enum HostOperatingSystem {

    /// The machine setting the build is written under in `semel.machine.config`.
    public static let buildMachineSettingKey = "hostOSBuild"

    /// The running system's build, `kern.osversion` — `25G5048a` — read once. Nil when the
    /// kernel does not say, which keys as though the line were absent rather than failing a
    /// build. Read through `sysctl` rather than `sw_vers`: no process is launched for it.
    ///
    /// A variable so that a test can stand for a machine on another build.
    public static var build: String? = kernelOSVersion()

    /// A node's line of key material for the system it ran on, or nil when the build is not
    /// known.
    public static var cacheKeyMaterial: String? {
        build.map { "os=\($0)" }
    }

    /// The machine setting, as a namespace's `machineSettings` returns it.
    public static var machineSettings: [String: String] {
        build.map { [buildMachineSettingKey: $0] } ?? [:]
    }

    private static func kernelOSVersion() -> String? {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0 else {
            return nil
        }
        let version = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return version.isEmpty ? nil : version
    }
}
