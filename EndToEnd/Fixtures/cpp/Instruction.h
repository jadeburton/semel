//
// Created by Jade Burton on 11.03.26.
//

#pragma once

#include <iostream>
#include <array>
#include <cassert>

#pragma pack(push)
#pragma pack(1)
class Instruction
{

public:

    struct InstructionDefinition;
//    typedef void (InstructionDefinition::*InstructionExecutor)(const Instruction& instruction, VirtualMachine& virtualMachine) const;

    typedef void (*InstructionExecutor)(const Instruction& instruction, VirtualMachine& virtualMachine);

    struct InstructionDefinition
    {
        [[nodiscard]] constexpr const char *getOpCodeName() const { return opCodeName; }
        [[nodiscard]] InstructionExecutor getExecutor(const int subcycle) const { return executor[subcycle]; }
        [[nodiscard]] constexpr uint8_t getLength() const { return length; }
        [[nodiscard]] constexpr uint8_t getCycleCount() const { return cycleCount; }

        template<class G>
        InstructionDefinition(const G& group,
                              const char *opCodeName,
                              const InstructionExecutor cycle0,
                              const InstructionExecutor cycle1,
                              const InstructionExecutor cycle2,
                              const InstructionExecutor cycle3,
                              const uint8_t length): opCodeName(opCodeName),
                                                     executor{cycle0, cycle1, cycle2, cycle3},
                                                     length(length)
        {
            cycleCount = 0;
            for (const auto& oneExecutor : executor)
            {
                if (oneExecutor == nullptr)
                {
                    break;
                }
                cycleCount++;
            }

            group.enumerateAll([this] (const uint8_t opCodeValue) -> bool
            {
                registerDefinition(opCodeValue, *this);
                return true;
            });
        }

        void moveToNext(VirtualMachine& virtualMachine) const
        {
            virtualMachine.write(SFR16::PC, virtualMachine.read(SFR16::PC) + getLength());
        }

        void moveToRelativeJumpAddress(VirtualMachine& virtualMachine, const Instruction& instruction) const
        {
            virtualMachine.write(SFR16::PC, (virtualMachine.read(SFR16::PC) + static_cast<int8_t>(instruction.params.two8s.p1)) + getLength());
        }

        static std::array<InstructionDefinition, 256> definitions;

        [[nodiscard]] static const InstructionDefinition& getDefinition(const uint8_t opCode)
        {
            if (definitions[opCode].getLength() == 0)
            {
                std::cout << "opcode 0x" << std::hex << static_cast<int>(opCode) << " has no instruction defined\n";
                assert(false);
                return definitions[0];
            }

            return definitions[opCode];
        }

        static void registerDefinition(const uint8_t opCode, const InstructionDefinition& instructionDefinition)
        {
            // Instruction must not already be defined
            if (definitions[opCode].getLength() != 0)
            {
                std::cout << instructionDefinition.getOpCodeName() << " already defined for 0x" << std::hex << static_cast<int>(opCode) << "\n";
                return;
            }

            definitions[opCode] = instructionDefinition;
        }

    private:
        const char *opCodeName;
        InstructionExecutor executor[4];
        uint8_t length;
        uint8_t cycleCount;
    };

    uint8_t opCode;

    union ParameterType
    {
        struct TwoBytes
        {
            uint8_t p1;
            uint8_t p2;
        } two8s;

        uint16_t one16;
    };

    ParameterType params;

    [[nodiscard]] const InstructionDefinition& getDefinition() const
    {
        return InstructionDefinition::getDefinition(opCode);
    }

    void execute(VirtualMachine& virtualMachine, const int subcycle) const
    {
        // Syntax boggle: get pointer to member function with implicit `this` argument (pointing to an InstructionDefinition)
//        (instructionDefinition.*instructionDefinition.getExecutor(subcycle))(*this, virtualMachine);

        getDefinition().getExecutor(subcycle)(*this, virtualMachine);
    }
};
#pragma pack(pop)

class OpCodeRange
{
    uint8_t minOpCode;
    uint8_t maxOpCodeInclusive;

public:

    constexpr OpCodeRange(const uint8_t minOpCode, const uint8_t maxOpCodeInclusive):
        minOpCode(minOpCode), maxOpCodeInclusive(maxOpCodeInclusive)
    {
    }

    void enumerateAll(const std::function<bool (uint8_t opCode)>& callback) const
    {
        for (int opCode = minOpCode; opCode <= static_cast<int>(maxOpCodeInclusive); opCode++)
        {
            if (!callback(static_cast<uint8_t>(opCode)))
            {
                break;
            }
        }
    }

    [[nodiscard]] int getIndexFromOpCode(const uint8_t opCode) const
    {
        return opCode - minOpCode;
    }
};

template<size_t N>
class OpCodeGroup
{
    std::array<uint8_t, N> opCodes;
    std::map<uint8_t, int> indicesByOpCode;

public:
    explicit constexpr OpCodeGroup(std::array<uint8_t, N>&& opCodesParam): opCodes(std::move(opCodesParam))
    {
        int index = 0;
        for (uint8_t opCode : opCodes)
        {
            indicesByOpCode.insert({ opCode, index++ });
        }
    }

    void enumerateAll(const std::function<bool (uint8_t opCode)>& callback) const
    {
        for (const uint8_t opCode : opCodes)
        {
            if (!callback(opCode))
            {
                break;
            }
        }
    }

    [[nodiscard]] int getIndexFromOpCode(const uint8_t opCode) const
    {
        // TODO: error handling
        return indicesByOpCode.find(opCode)->second;
    }
};

template<std::size_t S>
OpCodeGroup(const int (&)[S]) -> OpCodeGroup<S>;

