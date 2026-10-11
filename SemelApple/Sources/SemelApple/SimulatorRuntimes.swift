// SimulatorRuntimes.swift
// SemelApple
//
// The simulator runtimes installed for a platform, as a machine fact (B-153's audit). actool
// compiles an iOS catalog, and ibtool an iOS document, through the frameworks of the iOS
// simulator runtime rather than the Mac's own — without one installed, actool fails outright
// ("No simulator runtime version … available"). Runtimes are installed apart from Xcode and
// differ between machines with one Xcode, so a node compiling for such a platform folds
// them into its key, and the namespace writes them as a machine setting beside the SDK.

import Foundation
import SemelNodeKit

enum SimulatorRuntimes {

    /// The machine setting the runtimes are written under in `semel.machine.config`.
    static let machineSettingKey = "simulatorRuntimes"

    /// The runtimes available for a platform family (`iOS`, `tvOS`, `watchOS`, `xrOS`), as
    /// one line: `identifier@build`, sorted, comma-joined — or nil when none is installed
    /// or the machine does not say. A variable so that a test can stand for a machine with
    /// other runtimes; the machine is asked once per process.
    static var provider: (String) -> String? = { family in installed.runtimes(forFamily: family) }

    /// The family a platform name of actool's `--platform` belongs to; nil for the Mac's,
    /// which compiles through the Mac's own frameworks.
    static func family(ofPlatformName name: String) -> String? {
        let lowercased = name.lowercased()
        if lowercased.hasPrefix("iphone") {
            return "iOS"
        }
        if lowercased.hasPrefix("appletv") {
            return "tvOS"
        }
        if lowercased.hasPrefix("watch") {
            return "watchOS"
        }
        if lowercased.hasPrefix("xr") {
            return "xrOS"
        }
        return nil
    }

    /// The family of the SDK at `path`, by its folder's name: `iPhoneSimulator26.5.sdk`.
    static func family(ofSDKPath path: String) -> String? {
        family(ofPlatformName: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// A node's line of key material for the runtimes of `family`, or nil for none.
    static func cacheKeyMaterial(family: String?) -> String? {
        family.flatMap(provider).map { "runtimes=\($0)" }
    }

    // MARK: - The machine's answer

    private static let installed = InstalledRuntimes()

    /// `xcrun simctl list runtimes -j`, asked once and kept.
    private final class InstalledRuntimes {
        private let lock = NSLock()
        private var answer: [String: String]??

        func runtimes(forFamily family: String) -> String? {
            lock.withLock {
                if case .some(let known) = answer {
                    return known?[family]
                }
                let asked = Self.ask()
                answer = .some(asked)
                return asked?[family]
            }
        }

        private struct Listing: Decodable {
            struct Runtime: Decodable {
                let identifier: String
                let buildversion: String
                let platform: String?
                let isAvailable: Bool
            }
            let runtimes: [Runtime]
        }

        private static func ask() -> [String: String]? {
            guard let output = MachineQuery.output(of: "/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"]),
                  let listing = try? JSONDecoder().decode(Listing.self, from: Data(output.utf8)) else {
                return nil
            }
            var byFamily: [String: [String]] = [:]
            for runtime in listing.runtimes where runtime.isAvailable {
                guard let family = runtime.platform else {
                    continue
                }
                byFamily[family, default: []].append("\(runtime.identifier)@\(runtime.buildversion)")
            }
            return byFamily.mapValues { $0.sorted().joined(separator: ",") }
        }
    }
}
