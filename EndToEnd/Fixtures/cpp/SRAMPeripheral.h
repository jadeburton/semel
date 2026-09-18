//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>

#include "IAddressBusPeripheral.h"

class SRAMPeripheral final : public IAddressBusPeripheral
{
    uint8_t bytes[1024 * 64]{};

public:

    bool write(const u_int16_t address, const uint8_t value) override
    {
        // std::cout << std::hex << "WriteSRAM(" << address << ", " << (int)value << ")\n";

        bytes[address] = value;
        return false;
    }

    [[nodiscard]] std::tuple<bool, uint8_t> read(const u_int16_t address) const override
    {
        const auto result = bytes[address];
        // std::cout << std::hex << "ReadSRAM(" << (int)address << ") -> " << (int)result << "\n";
        return {true, result};
    }
};