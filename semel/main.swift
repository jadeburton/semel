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

var commandInterpreter: CommandInterpreter?

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
    print("Semel \(server.serverVersion) (C) 2026 Jade Burton. All rights reserved.")
    print("Graph: \(server.databasePath)")

    commandInterpreter = interpreter

    // Non-interactive: each argument is one command line, run in order, then exit —
    // non-zero if any command reported an error. `semel 'build Packages'` is a build step;
    // `semel 'base /repo' 'push src' wait errors` is the same thing spelled out.
    let scripted = Array(CommandLine.arguments.dropFirst())
    if !scripted.isEmpty {
        for command in scripted {
            guard receiveUserInput(line: command) else {
                break
            }
        }
        exit(interpreter.errorsReported == 0 ? 0 : 1)
    }

    while let line = readLine(), receiveUserInput(line: line) {
    }
}

func receiveUserInput(line: String) -> Bool {
    do {
        try commandInterpreter?.handleCommand(line)
        return true
    } catch {
        return false
    }
}

#if !UNIT_TESTING
try main()
#endif
