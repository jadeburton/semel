//
//  main.swift
//  semelserv
//
//  The engine behind a Unix-domain socket. Start it in a terminal or under launchd; it
//  logs to standard output and error and stops cleanly on SIGINT or SIGTERM, or when its
//  socket file is deleted. One per user: a second instance finds the first through the
//  socket file and exits.
//

import Foundation
import SemelApple
import SemelClang
import SemelCore
import SemelExamples
import SemelNodeKit
import SemelProtocol
import SemelServer
import SemelSwift

// `print` writes through the C stream `stdout`, which glibc and Darwin's libc both
// fully-buffer once it is not a terminal — a redirected log then holds back everything
// short of a full buffer until the process exits. A daemon's log must be complete and
// current the moment someone tails it, so line-buffer before the first print.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("semelserv: \(message)\n".utf8))
    exit(code)
}

let socketPath = SemelPaths.serverSocket.path

// The socket is taken before anything else, because losing the race must cost nothing: a
// second instance that opened the graph first would reset the running one's graph on a
// version change and only then learn it was second.
do {
    try Server.claimSocket(at: socketPath)
} catch let error as ServerError {
    fail(error.description, code: 1)
} catch {
    fail("\(error)", code: 1)
}

// What the signal handler is allowed to touch. The engine and the server are built after
// the socket is claimed, so a signal arriving in between has only the file to clean up.
var engineStarted   = false
var runningServer: Server?

/// The orderly stop: a signal, or the socket file disappearing once the server listens.
/// Safe before the engine and the server exist, when there is only the file to clean up.
func stopCleanly() {
    if engineStarted {
        BuildEngine.shared.stopProcessingLoop()
    }
    guard let runningServer else {
        try? FileManager.default.removeItem(atPath: socketPath)
        exit(0)
    }
    runningServer.terminate(code: 0)
}

// Signals: ignore the default disposition, then handle on a queue so the stop runs on an
// ordinary thread with the listener's locks available. Installed before the engine, so a
// signal during startup unwinds what exists instead of killing the process where it
// stands and leaving the claimed socket file behind.
let signalQueue = DispatchQueue(label: "semelserv.signals")
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler { stopCleanly() }
    source.resume()
    signalSources.append(source)
}

// Composition root: the engine knows no node packages, so this is where the ones this
// binary ships are installed. Before start(), so discovery sees them on its first pass.
do {
    try SemelSwift.register()
    try SemelClang.register()
    try SemelApple.register()
    try SemelExamples.register()
    try BuildEngine.start()
    engineStarted = true
} catch {
    try? FileManager.default.removeItem(atPath: socketPath)
    fail("cannot start the engine: \(error)", code: 1)
}

let handler = RequestHandler(engine: BuildEngine.shared,
                             database: DatabaseLayer.shared,
                             databasePath: SemelPaths.database.path)
let server = Server(handler: handler, socketPath: socketPath)
server.onSocketFileRemoved = stopCleanly
runningServer = server

// A machine failure ends the process, but only after the client that hit it has its
// answer. The server marks itself stopping first so nothing new is accepted meanwhile.
FatalErrors.handler = { error in
    server.handleFatal(error) { code in exit(code) }
}

do {
    try server.start()
} catch let error as ServerError {
    // The file is ours only if nobody else answered on it.
    if case .alreadyRunning = error {
        fail(error.description, code: 1)
    }
    try? FileManager.default.removeItem(atPath: socketPath)
    fail(error.description, code: 1)
} catch {
    try? FileManager.default.removeItem(atPath: socketPath)
    fail("\(error)", code: 1)
}

print("Semel server \(Semel.version)")
print("Graph:  \(SemelPaths.database.path)")
print("Socket: \(socketPath)")
// A setting that silently fell back would be one nobody could trust, so an unusable
// SEMEL_JOBS is named here beside the value that stands in for it.
let jobs = Jobs.resolve()
print("Jobs:   \(BuildEngine.shared.jobs)"
      + (jobs.ignored.map { " (\(Jobs.variable)=\($0) ignored: not a positive integer)" } ?? ""))

dispatchMain()
