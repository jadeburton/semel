//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>
#include <fstream>

#include "IAddressBusPeripheral.h"

// TODO: there are different kinds of hard loops. a hard loop that just updates the SP but
// nothing else is probably a deliberate tight while loop.
// but a hard loop that causes an external peripheral to receive a write, that is not RAM,
// is probably an intentional loop that we don't want to slow down.
// a repeated write to RAM, but not ports, with the same values and addresses over and over is a hard loop.
class HardLoopDetector final : public IAddressBusPeripheral
{
public:
    HardLoopDetector() = default;
    ~HardLoopDetector() override = default;

    [[nodiscard]] bool isHardLoopDetected() const
    {
        return countRightToLeftRepeats(recentDestructiveActions) > 10;
    }

    void writeRegister16Bit(const SFR16 sfr, const uint16_t value)
    {
        append("R" + std::to_string(static_cast<uint8_t>(sfr)) + "_" + std::to_string(value) + ",");
    }

    void writeRegister8Bit(const SFR sfr, const uint8_t value)
    {
        append("R" + std::to_string(static_cast<uint8_t>(sfr)) + "_" + std::to_string(value) + ",");
    }

private:
    bool write(const u_int16_t address, const uint8_t value) override
    {
        append(std::to_string(address) + "_" + std::to_string(value) + ",");

        // We act "transparently", such that other peripherals do the write after this
        return false;
    }

    void append(const std::string& str)
    {
        recentDestructiveActions += str;

        // HACK: slow
        // HACK: can cut mid-character
        while (recentDestructiveActions.size() > 1000)
        {
            recentDestructiveActions.erase(recentDestructiveActions.begin());
        }
    }

    [[nodiscard]] std::tuple<bool, uint8_t> read(u_int16_t address) const override
    {
        return {false, 0};
    }

    // TODO: make this a ring buffer of address-byte pairs
    std::string recentDestructiveActions;

    static size_t countRightToLeftRepeats(const std::string_view& input) {
        if (input.empty()) return 0;

        size_t maxRepeats = 0;

        // Iterate through potential pattern lengths and find the maximum repetitions
        for (size_t patternLength = 1; patternLength <= input.size() / 2; ++patternLength) {
            if (size_t currentRepeats = countConsecutiveSuffixMatches(input, patternLength); currentRepeats > 1) {
                maxRepeats = std::max(maxRepeats, currentRepeats);
            }
        }

        return maxRepeats;
    }

    static size_t countConsecutiveSuffixMatches(const std::string_view& input, const size_t patternLength) {
        if (patternLength == 0 || patternLength > input.size()) return 0;

        const std::string_view pattern = input.substr(input.size() - patternLength);
        size_t count = 0;
        size_t pos = input.size();

        while ((pos >= patternLength) && (input.substr(pos - patternLength, patternLength) == pattern)) {
            count++;
            pos -= patternLength;
        }

        return count;
    }
};
