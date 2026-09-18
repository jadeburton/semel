//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>

class IAddressBusPeripheral
{
public:
    virtual ~IAddressBusPeripheral() = default;

    virtual bool write(u_int16_t address, uint8_t value) = 0;
    [[nodiscard]] virtual std::tuple<bool, uint8_t> read(u_int16_t address) const = 0;
};
enum class SFlags: uint8_t
{
    N = (1 << 7), // Negative
    V = (1 << 6), // Overflow
    B = (1 << 4), // Break
    D = (1 << 3), // Decimal
    I = (1 << 2), // Interrupt
    Z = (1 << 1), // Zero
    C = (1 << 0), // Carry
};

enum class SFR: uint8_t
{
    AC,
    X,
    Y,
    SR,
    SP,
    _Count
};

enum class SFR16: uint8_t
{
    PC,
    _Count
};