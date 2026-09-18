//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>
#include <fstream>
#include <functional>

class LCDisplay
{
    const uint8_t E = 0b10000000;
    const uint8_t RW = 0b01000000;
    const uint8_t RS = 0b00100000;

    std::string buffer;
    uint8_t firstPortValue; // E = b7, RW = b6, RS = b5
    uint8_t secondPortValue; // data write when mcu is outputting, otherwise read

public:
    LCDisplay(PortPeripheral& firstPort, PortPeripheral& secondPort)
    {
        firstPortValue = 0x00;
        secondPortValue = 0b00000000;

        firstPort.registerOnWriteCallback([this] (const uint8_t value, const uint8_t bitMask)
        {
            std::cout << std::hex << "Control port write: " << static_cast<int>(value) << "\n";

            std::cout << "   E (enable) = " << (((value & E) != 0) ? 1 : 0) << "\n";
            std::cout << "   RW (read-write) = " << (((value & RW) == 0) ? "write" : "read") << "\n";
            std::cout << "   RS (register select) = " << (((value & RS) == 0) ? "instruction" : "data") << "\n";

            const auto oldValue = firstPortValue;
            firstPortValue = (firstPortValue & ~bitMask) | (value & bitMask);

            if ((oldValue & E) != (firstPortValue & E))
            {
                // data + write + enable rise
                if (((value & RS) != 0) && ((value & RW) == 0) && (firstPortValue & E) != 0)
                {
                    buffer += static_cast<char>(secondPortValue);
                    std::cout << std::hex << "BUFFER: '" << buffer << "'\n";
                }
            }
        });
        /*
         send "instruction" 0b00111000 to set 8-bit mode, 2-line display, 5x8 font
         send instruction 0b00001110 - Display on; cursor on; blink off
         send instruction 0b00000110
         send instruction 0b00000001

         let X = 0

         let A = byte at: (address of "Hello, World!") + X
         if A == 0 then halt
         call print_char
         X++
         loop


         sending instruction:
            wait until ready
            send to port B: AC
            send 0 to port A to clear RS/RW/E
            send E bit to port A
            send 0 to port A to clear RS/RW/E


         print_char:
            wait until ready
            send to port B: AC

            send RS to port A to Set RS; Clear RW/E bits
            send (RS | E) to port A to Set E bit to send instruction
            send RS to port A to Clear RS/RW/E bits

         wait until ready
            push A to stack
            make port B input for all bits

        loop:
            send RW to port A
            send (RW | E) to port A
            let A = port B value
            let A = A & 0b10000000
            loop if not zero (Z = 0 means not zero, Z = 1 means zero) (so we loop while the bit is set in port B)

            send RW to port A
            make port B output for all bits

            pop A from stack
            return

         */

        secondPort.registerOnWriteCallback([this] (const uint8_t value, const uint8_t bitMask)
        {
            secondPortValue = (secondPortValue & ~bitMask) | (value & bitMask);
        });

        firstPort.registerOnReadCallback([this] (const uint8_t bitMask) -> uint8_t
        {
            return firstPortValue & bitMask;
        });

        secondPort.registerOnReadCallback([this] (const uint8_t bitMask) -> uint8_t
        {
            return secondPortValue & bitMask;
        });
    }
};
