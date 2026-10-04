//
//  main.swift
//  semel-watch
//
//  A watcher that pushes as you save (B-126): a fourth client of `semelserv`, beside
//  `semel`, `semel-swift` and `semel-clang`. It observes a tree with FSEvents and, after
//  two quiet seconds, issues one batch of the commands a person would type — `push` for
//  what exists, `rm` for what went — so that saving a file is building it.
//
//  The engine never reads a disk it did not receive through a push; that is what keeps a
//  graph independent of where its tree is mounted. So the watching happens here, in a
//  process of its own, started and stopped like an editor.
//

import Foundation
import SemelCLI
import SemelNodeKit
import SemelWatch

/// Opens a connection as `semel` opens one: to the engine at the socket, starting
/// `semelserv` beside this executable when none answers (B-110).
struct SocketWatchConnector: WatchConnector {
    let socketPath: String
    let base: String
    let printsReports: Bool
    let progress: ProgressPolicy.Mode

    func connect() throws -> WatchSession {
        let connection: SocketConnection
        do {
            connection = try SocketConnection.connect(to: socketPath)
        } catch ConnectionError.unavailable {
            connection = try ServerLauncher.start(socketPath: socketPath) { print($0) }
        }
        let interpreter = CommandInterpreter(connection: connection, baseDirectory: base,
                                             progress: printsReports ? progress : .off)
        let server = try interpreter.connect(subscribing: printsReports)
        return WatchSession(interpreter: interpreter, serverVersion: server.serverVersion,
                            databasePath: server.databasePath, isOpen: { connection.isOpen })
    }
}

func fail(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("semel-watch: \(message)\n".utf8))
    exit(status)
}

// Line by line into a pipe as well as a terminal: a watcher runs for hours, and a reader
// of its output — the prompt that started it, a log, a test — wants each line as it is
// printed, not a buffer's worth at a time.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(WatchConfiguration.usage)
    exit(0)
}

let configuration: WatchConfiguration
do {
    configuration = try WatchConfiguration.parse(arguments, currentDirectory: FileManager.default.currentDirectoryPath)
} catch {
    fail("\(error)\n\(WatchConfiguration.usage)", status: 2)
}

let stream: FSEventsStream
do {
    stream = try FSEventsStream(base: configuration.base, latency: configuration.quietInterval)
} catch {
    fail("\(error)", status: 1)
}

// SIGINT and SIGTERM end the stream, and with it the loop; the engine and the graph are
// left as they are, so the next `semel` sees what was pushed. A batch under way is given
// a moment to finish its settle, and then the process goes regardless: what it had not
// pushed or removed, the next launch's initial batch will.
let signalQueue = DispatchQueue(label: "semel-watch.signals")
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler {
        stream.stop()
        let grace = 2.0
        signalQueue.asyncAfter(deadline: .now() + grace) { exit(0) }
    }
    source.resume()
    signalSources.append(source)
}

let watcher = Watcher(configuration: configuration,
                      events:        stream,
                      clock:         SystemWatchClock(),
                      connector:     SocketWatchConnector(socketPath:    SemelPaths.serverSocket.path,
                                                          base:          configuration.base,
                                                          printsReports: configuration.printsReports,
                                                          progress:      ProgressPolicy.modeInThisProcess()))
do {
    try watcher.run()
} catch {
    fail("\(error)", status: 1)
}
exit(0)
