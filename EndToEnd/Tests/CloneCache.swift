//
//  CloneCache.swift
//  SemelEndToEndTests
//
//  A pinned commit, fetched once into the cache as a checkout of that commit alone and
//  copied out for every run. The cache holds the raw checkout only; nothing is ever
//  built in it, so a run cannot poison the next.
//

import Foundation
import SemelTestSupport

enum CloneCache {

    static func checkout(name: String, url: String, commit: String) throws -> URL {
        let directory = EndToEndEnvironment.cacheDirectory.appendingPathComponent("\(name)-\(commit)", isDirectory: true)
        let marker = directory.appendingPathComponent(".semel-e2e-complete")
        if FileManager.default.fileExists(atPath: marker.path) {
            return directory
        }
        // A half-fetched checkout from an interrupted run is removed and fetched again.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q"], in: directory)
        try git(["fetch", "-q", "--depth", "1", url, commit], in: directory)
        try git(["checkout", "-q", "FETCH_HEAD"], in: directory)
        try Data().write(to: marker)
        return directory
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = ManagedProcess(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments,
                                     environment: [:], currentDirectory: directory)
        try process.start()
        let status = process.waitForExit(timeout: 15 * 60)
        guard status == 0 else {
            process.kill()
            throw EndToEndFailure(step: "fetch", message: status.map { "exit status \($0)" } ?? "timed out",
                                  commandLine: process.commandLine, status: status, outputTail: process.outputTail())
        }
    }
}
