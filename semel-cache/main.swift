//
//  main.swift
//  semel-cache
//
//  The shared cache (B-153): a store of entries and objects under a home folder, answered
//  over TCP to the engines that read from it and write to it. `serve` runs until SIGINT or
//  SIGTERM; `status` and `purge` act on the home, through the running server when there is
//  one. It links the cache, the transport, the protocol and the node kit, and never the
//  engine (AGENTS.md).
//

import Foundation
import SemelCacheServer

// A server's log must be current the moment someone tails it: line-buffer standard output
// before the first print, as `semelserv` does.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("semel-cache: \(message)\n".utf8))
    exit(code)
}

let command: CacheCommand
do {
    command = try CacheCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(CacheCommand.usage)", code: 2)
}

switch command {
case .help:
    print(CacheCommand.usage)
    exit(0)

case .status(let home):
    do {
        try CacheAdministration.status(home: home).forEach { print($0) }
        exit(0)
    } catch {
        fail("\(error)", code: 1)
    }

case .purge(let home, let target):
    do {
        try CacheAdministration.purge(home: home, target: target).forEach { print($0) }
        exit(0)
    } catch {
        fail("\(error)", code: 1)
    }

case .serve(let home, let settings):
    let server: CacheServer
    do {
        server = try CacheServer(home: home, overrides: settings)
        try server.start()
    } catch {
        fail("\(error)", code: 1)
    }

    // The stop runs on an ordinary queue, so the listener's locks are free to it: every
    // connection closed, what is queued written, the home let go.
    let signalQueue = DispatchQueue(label: "semel-cache.signals")
    var signalSources: [DispatchSourceSignal] = []
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
        source.setEventHandler {
            server.stop()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    server.banner.forEach { print($0) }
    dispatchMain()
}
