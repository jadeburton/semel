// Jobs.swift
// SemelCore
//
// How many nodes the engine computes at once (B-114). A declared limit, as `make -j` is,
// rather than whatever the concurrency runtime's thread count happens to be: every
// running tool is a process of its own, and the number of them is a setting about this
// machine's load, not about Swift's pool.

import Foundation
import SemelNodeKit

public enum Jobs {

    /// The environment variable: a positive integer, the number of nodes to compute at
    /// once. Unset, the machine's core count.
    public static let variable = "SEMEL_JOBS"

    /// The limit for `environment`, and the value that was ignored when one was set and
    /// was not a positive integer — said rather than swallowed, since a setting that
    /// silently falls back is a setting nobody can trust.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (count: Int, ignored: String?) {
        guard let value = environment[variable], !value.isEmpty else {
            return (MachineQuery.activeProcessorCount, nil)
        }
        guard let count = Int(value), count > 0 else {
            return (MachineQuery.activeProcessorCount, value)
        }
        return (count, nil)
    }
}
