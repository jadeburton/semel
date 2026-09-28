//
//  main.swift
//  semel
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import SemelCLI
import SemelNodeKit
import SemelProtocol

func main() throws {
    // The client half only. The engine, the graph and the toolchains live in semelserv;
    // this process opens a socket to it and hands the connection to the interpreter —
    // starting a semelserv first when none answers (B-110).
    let socketPath = SemelPaths.serverSocket.path
    let scripted = Array(CommandLine.arguments.dropFirst())

    // `semel stop` is the one command that wants no server: it ends the one there is.
    if scripted == ["stop"] {
        ServerLauncher.stop(socketPath: socketPath) { print($0) }
        exit(0)
    }

    let connection: SocketConnection
    do {
        connection = try SocketConnection.connect(to: socketPath)
    } catch ConnectionError.unavailable {
        do {
            connection = try ServerLauncher.start(socketPath: socketPath) { print($0) }
        } catch {
            FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
        exit(1)
    }
    // The progress indicator is the terminal's: drawn while a command waits for a settle
    // when standard output is one, never into a pipe; the dashboard at `SEMEL_PROGRESS=full`
    // (B-95).
    let interpreter = CommandInterpreter(connection: connection, progress: ProgressPolicy.modeInThisProcess())

    let server: (serverVersion: String, databasePath: String)
    do {
        server = try interpreter.connect()
    } catch {
        FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
        exit(1)
    }
    print("Semel \(server.serverVersion)")
    print("Graph: \(server.databasePath)")

    // Non-interactive: each argument is one command line, run in order, then exit —
    // non-zero if any command reported an error. `semel 'build Packages'` is a build step;
    // `semel 'base /repo' 'push src' wait errors` is the same thing spelled out.
    if !scripted.isEmpty {
        for command in scripted where interpreter.handleCommand(command) == .quit {
            break
        }
        exit(interpreter.errorsReported == 0 ? 0 : 1)
    }

    // Interactive: a failed command is reported and the prompt continues; only quit ends
    // the session.
    while let line = readLine(), interpreter.handleCommand(line) != .quit {
    }
}

#if !UNIT_TESTING
try main()
#endif
