//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import BuildSystemCore

var commandInterpreter: CommandInterpreter?

func main() throws {
    print("Build System 1.0 (C) 2026 Jade Burton. All rights reserved.")

    try BuildEngine.start()

    commandInterpreter = CommandInterpreter(database: DatabaseLayer.shared)
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
