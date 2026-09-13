//
//  main.swift
//  semel
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import SemelCore
import SemelCLI
import SemelNodeKit
import SemelProtocol
import SemelServ
import SemelSwift
import SemelClang

var commandInterpreter: CommandInterpreter?

func main() throws {
    // Composition root: the engine knows no toolchains, so this is where the ones this
    // binary ships are installed. Before start(), so discovery sees them on its first pass.
    try SemelSwift.register()
    try SemelClang.register()

    try BuildEngine.start()

    // The server half and the client half, joined in one process by a connection that
    // still puts every message through the wire codec. The process-wide engine and
    // database are resolved once, here, and handed to the handler.
    let handler    = RequestHandler(engine: BuildEngine.shared,
                                    database: DatabaseLayer.shared,
                                    databasePath: SemelPaths.database.path)
    let connection = InProcessConnection(handler: handler)
    let interpreter = CommandInterpreter(connection: connection)

    let server = try interpreter.connect()
    print("Semel \(server.serverVersion) (C) 2026 Jade Burton. All rights reserved.")
    print("Graph: \(server.databasePath)")

    commandInterpreter = interpreter
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
