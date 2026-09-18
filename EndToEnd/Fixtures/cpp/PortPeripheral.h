//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>
#include <vector>
#include <functional>

#include "IAddressBusPeripheral.h"

class PortPeripheral final : public IAddressBusPeripheral
{
    uint16_t portAddress;
    uint16_t inputOutputAddress;
    uint8_t inputOutputMode;
    std::vector<std::function<void (uint8_t newValue, uint8_t bitMask)>> onWriteValueCallbacks;
    std::optional<std::function<uint8_t (uint8_t bitMask)>> readValueCallback = {};

public:

    void registerOnWriteCallback(const std::function<void (uint8_t newValue, uint8_t bitMask)>& onValueChanged)
    {
        onWriteValueCallbacks.push_back(onValueChanged);
    }

    void registerOnReadCallback(const std::function<uint8_t (uint8_t bitMask)>& readValue)
    {
        readValueCallback = readValue;
    }

    [[nodiscard]] uint16_t address() const
    {
        return portAddress;
    }

    explicit PortPeripheral(const uint16_t portAddress, const uint16_t inputOutputAddress):
        portAddress(portAddress),
        inputOutputAddress(inputOutputAddress),
        inputOutputMode(0)
    {
    }

    bool write(const u_int16_t address, const uint8_t value) override
    {
        // 1s in the inputOutputMode mean "output"; writing to the port causes updates to connected peripherals
        // 0s in the inputOutputMode mean "input"; writing does nothing. reading causes read requests to peripherals.
        if (address == portAddress)
        {
            std::cout << std::hex << "WritePort(" << static_cast<int>(portAddress) << ", " << static_cast<int>(value) << ")\n";

            for (const auto& callback : onWriteValueCallbacks)
            {
                callback(value, inputOutputMode);
            }
            return true;
        }

        if (address == inputOutputAddress)
        {
            std::cout << std::hex << "SetPortInputOutputMode(" << static_cast<int>(inputOutputAddress) << ", " << static_cast<int>(value) << ")\n";

            inputOutputMode = value;
            return true;
        }

        return false;
    }

    [[nodiscard]] std::tuple<bool, uint8_t> read(const u_int16_t address) const override
    {
        if (address == portAddress)
        {
            if (readValueCallback.has_value())
            {
                const auto value = readValueCallback.value()(~inputOutputMode) & ~inputOutputMode;
                std::cout << std::hex <<"ReadPort(" << static_cast<int>(address) << ") -> " << static_cast<int>(value) << "\n";
                return {true, value};
            }
            std::cout << std::hex <<"ReadPort(" << static_cast<int>(address) << ") -> 0 (no handler)" << "\n";
        }

        if (address == inputOutputAddress)
        {
            return {true, inputOutputMode};
        }

        return {false, 0};
    }
};