//
// Created by Jade Burton on 24.05.24.
//

#pragma once

#include <iostream>
#include <fstream>
#include <vector>
#include <functional>
#include <map>

#include "IAddressBusPeripheral.h"
#include "PortPeripheral.h"
#include "HardLoopDetector.h"
#include "SRAMPeripheral.h"
#include "LCDisplay.h"

#pragma pack(push)
#pragma pack(1)
class VirtualMachine
{
    uint8_t register8Bit[static_cast<size_t>(SFR::_Count)] = {0};
    uint16_t register16Bit[static_cast<size_t>(SFR16::_Count)] = {0};
    std::vector<IAddressBusPeripheral*> addressBusPeripherals;

public:

    uint64_t cycle;

    // Address-space peripherals
    SRAMPeripheral sram{};
    PortPeripheral portA{0x6001, 0x6003};
    PortPeripheral portB{0x6000, 0x6002};
    HardLoopDetector hardLoopDetector;

    // Peripherals that connect to ports
    LCDisplay *lcDisplay;

    VirtualMachine()
    {
        cycle = 0ul;
        reset();

        // This peripheral monitors writes but does not intercept them; they are passed through
        addressBusPeripherals.push_back(&hardLoopDetector);

        addressBusPeripherals.push_back(&portA);
        addressBusPeripherals.push_back(&portB);

        addressBusPeripherals.push_back(&sram);

        lcDisplay = new LCDisplay(portA, portB);
    }

    void reset()
    {
        // It is customary in the system reset routine to
        // initialize SP to $FF, as each time a byte is pushed to the stack SP is decremented.
        write(SFR::SP, 0xFF);
    }

    static constexpr uint16_t stackBase = 0x0100;

    void pushByte(const uint8_t byte)
    {
        uint8_t SP = read(SFR::SP);
        writeData(stackBase + static_cast<uint16_t>(SP), byte);
        SP--;
        write(SFR::SP, SP);
    }

    uint8_t popByte()
    {
        uint8_t SP = read(SFR::SP);
        SP++;
        write(SFR::SP, SP);
        const uint8_t byte = readData(stackBase + static_cast<uint16_t>(SP));
        return byte;
    }

    [[nodiscard]] uint16_t readData16(const uint16_t addr) const
    {
        return static_cast<uint16_t>(readData(addr)) | (static_cast<uint16_t>(readData(addr + 1)) << 8);
    }

    [[nodiscard]] uint8_t readZeroPage(const uint8_t addr) const
    {
        return readData(addr);
    }

    [[nodiscard]] uint16_t readCode16(const uint16_t addr) const
    {
        return readData16(addr);
    }

    void writeData16(const uint16_t addr, const uint16_t value) const
    {
        writeData(addr, static_cast<uint8_t>(value & 0x00FF));
        writeData(addr, static_cast<uint8_t>((value & 0xFF00) >> 8));
    }

    void writeCode16(const uint16_t addr, const uint16_t value) const
    {
        writeData16(addr, value);
    }

    [[nodiscard]] uint8_t readData(const uint16_t addr) const
    {
        for (const auto addressBusPeripheral: addressBusPeripherals)
        {
            bool handled;
            uint8_t value;
            std::tie(handled, value) = addressBusPeripheral->read(addr);

            if (handled)
            {
                return value;
            }
        }

        return 0x99;
    }

    [[nodiscard]] uint8_t readCode(const uint16_t addr) const
    {
        return readData(addr);
    }

    void writeCode(const uint16_t addr, const uint8_t value) const
    {
        writeData(addr, value);
    }

    void writeData(const uint16_t addr, const uint8_t value) const
    {
        for (const auto addressBusPeripheral: addressBusPeripherals)
        {
            if (addressBusPeripheral->write(addr, value))
            {
                return;
            }
        }
    }

    void writeZeroPage(const uint8_t addr, const uint8_t value) const
    {
        writeData(addr, value);
    }

    [[nodiscard]] uint8_t readFlag(const SFlags flag) const
    {
        return ((read(SFR::SR) & static_cast<uint8_t>(flag)) != 0) ? 0x01 : 0x00;
    }

    [[nodiscard]] bool readFlagAsBool(const SFlags flag) const
    {
        return ((read(SFR::SR) & static_cast<uint8_t>(flag)) != 0);
    }

    void writeFlag(const SFlags flag, const bool value)
    {
        write(SFR::SR, (read(SFR::SR) & ~static_cast<uint8_t>(flag)) | ((value == false) ? 0x00 : static_cast<uint8_t>(flag)));
    }

    void writeFlag(SFlags flag, uint8_t value) = delete;

    [[nodiscard]] uint8_t read(const SFR sfr) const
    {
        std::cout << std::hex << "read(" << registerName(sfr) << ") -> " << static_cast<int>(register8Bit[static_cast<size_t>(sfr)]) << "\n";
        return register8Bit[static_cast<size_t>(sfr)];
    }

    static void logStatusRegister(const uint8_t value)
    {
        static constexpr struct { SFlags flag; char symbol; } statusFlagMap[] = {
            {SFlags::N, 'N'}, {SFlags::V, 'V'}, {SFlags::B, 'B'},
            {SFlags::D, 'D'}, {SFlags::I, 'I'}, {SFlags::Z, 'Z'},
            {SFlags::C, 'C'}
        };

        std::cout << "SR = { ";
        for (const auto& [flag, symbol] : statusFlagMap)
        {
            if (value & static_cast<uint8_t>(flag))
            {
                std::cout << symbol << ' ';
            }
        }
        std::cout << "}\n";
    }

    void write(const SFR sfr, const uint8_t value)
    {
        std::cout << std::hex << "write(" << registerName(sfr) << ", " << static_cast<int>(value) << ")\n";
        if (sfr == SFR::SR)
        {
            logStatusRegister(value);
        }
        register8Bit[static_cast<size_t>(sfr)] = value;
        hardLoopDetector.writeRegister8Bit(sfr, value);
    }

    static const char *registerName(const SFR sfr)
    {
        switch (sfr)
        {
            case SFR::AC: return "AC";
            case SFR::X: return "X";
            case SFR::Y: return "Y";
            case SFR::SR: return "SR";
            case SFR::SP: return "SP";
            default: return "-";
        }
    }

    static const char *registerName(const SFR16 sfr)
    {
        switch (sfr)
        {
            case SFR16::PC: return "PC";
            default: return "-";
        }
    }

    [[nodiscard]] uint16_t read(const SFR16 sfr) const
    {
        std::cout << std::hex << "read16(" << registerName(sfr) << ") -> " << static_cast<int>(register16Bit[static_cast<size_t>(sfr)]) << "\n";
        return register16Bit[static_cast<size_t>(sfr)];
    }

    void write(const SFR16 sfr, const uint16_t value)
    {
        std::cout << std::hex << "write16(" << registerName(sfr) << ", " << static_cast<int>(value) << ")\n";
        register16Bit[static_cast<size_t>(sfr)] = value;
        hardLoopDetector.writeRegister16Bit(sfr, value);
    }

    [[noreturn]] void run();
};
#pragma pack(pop)
