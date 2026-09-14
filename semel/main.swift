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
    // this process opens a socket to it and hands the connection to the interpreter.
    let socketPath = SemelPaths.serverSocket.path
    let connection: SocketConnection
    do {
        connection = try SocketConnection.connect(to: socketPath)
    } catch {
        FileHandle.standardError.write(Data("semel: \(error)\n".utf8))
        exit(1)
    }
    let interpreter = CommandInterpreter(connection: connection)

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
    let scripted = Array(CommandLine.arguments.dropFirst())
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
