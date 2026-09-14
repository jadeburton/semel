//
//  main.swift
//  semelserv
//
//  The engine behind a Unix-domain socket. Start it in a terminal or under launchd; it
//  logs to standard output and error and stops cleanly on SIGINT or SIGTERM. One per
//  user: a second instance finds the first through the socket file and exits.
//

import Foundation
import SemelClang
import SemelCore
import SemelNodeKit
import SemelProtocol
import SemelServ
import SemelSwift

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("semelserv: \(message)\n".utf8))
    exit(code)
}

// Composition root: the engine knows no toolchains, so this is where the ones this
// binary ships are installed. Before start(), so discovery sees them on its first pass.
do {
    try SemelSwift.register()
    try SemelClang.register()
    try BuildEngine.start()
} catch {
    fail("cannot start the engine: \(error)", code: 1)
}

let handler = RequestHandler(engine: BuildEngine.shared,
                             database: DatabaseLayer.shared,
                             databasePath: SemelPaths.database.path)
let server = Server(handler: handler, socketPath: SemelPaths.serverSocket.path)

// A machine failure ends the process, but only after the client that hit it has its
// answer. The server marks itself stopping first so nothing new is accepted meanwhile.
FatalErrors.handler = { error in
    server.handleFatal(error) { code in exit(code) }
}

do {
    try server.start()
} catch let error as ServerError {
    fail(error.description, code: 1)
} catch {
    fail("\(error)", code: 1)
}

print("Semel server \(Semel.version)")
print("Graph:  \(SemelPaths.database.path)")
print("Socket: \(SemelPaths.serverSocket.path)")

// Signals: ignore the default disposition, then handle on a queue so the stop runs on an
// ordinary thread with the listener's locks available.
let signalQueue = DispatchQueue(label: "semelserv.signals")
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        server.stop()
        BuildEngine.shared.stopProcessingLoop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
