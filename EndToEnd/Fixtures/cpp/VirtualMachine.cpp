//
// Created by Jade Burton on 11.03.26.
//

#include "VirtualMachine.h"
#include "Instruction.h"

#include <iostream>
#include <iomanip>
#include <thread>
#include <chrono>

[[noreturn]] void VirtualMachine::run()
{
    cycle = 0;

    for (; ; cycle++)
    {
        Instruction instruction; // NOLINT(*-pro-type-member-init)
        uint16_t address = read(SFR16::PC);
        instruction.opCode = readCode(address++);

        const auto instructionLength = Instruction::InstructionDefinition::getDefinition(instruction.opCode).getLength();
        for (uint8_t i = 1; i < instructionLength; i++)
        {
            reinterpret_cast<uint8_t *>(&instruction)[i] = readCode(address++);
        }

        std::cout << std::hex << read(SFR16::PC) << " - " << instruction.getDefinition().getOpCodeName() << " [";

        for (uint8_t i = 0; i < instructionLength; i++)
        {
            std::cout << std::hex << std::setfill('0') << std::setw(2) << (int)((uint8_t*)&instruction)[i];
        }

        std::cout << "]\n";

        for (int subcycle = 0; subcycle < instruction.getDefinition().getCycleCount(); subcycle++)
        {
            instruction.execute(*this, subcycle);
        }

        if (hardLoopDetector.isHardLoopDetected())
        {
            std::cout << "Pausing due to suspected hard loop\n";
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
        }
    }
}
