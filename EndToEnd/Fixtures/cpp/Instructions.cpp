#include "VirtualMachine.h"
#include "Instruction.h"
#include "InstructionMacros.h"

template<std::size_t N, typename T, std::size_t... Is>
constexpr std::array<T, N> make_filled_array(
        std::index_sequence<Is...>,
        T const& value
)
{
    return {((void)Is, value)...};
}

template<std::size_t N, typename T>
constexpr std::array<T, N> make_filled_array(T const& value)
{
    return make_filled_array<N>(std::make_index_sequence<N>(), value);
}

std::array<Instruction::InstructionDefinition, 256> Instruction::InstructionDefinition::definitions =
        make_filled_array<256, Instruction::InstructionDefinition>(Instruction::InstructionDefinition(OpCodeRange(0, 0), "", nullptr, nullptr, nullptr, nullptr, 0));


#define vm virtualMachine
#define p instruction.params

// ADC        add with carry

// C = 0
//     1000 0000
// +   1000 0000
// = 1 0000 0000  C = 1

// C = 1
//     0000 1100
// +   0000 0010
// +   0000 0001  from C
// =   0000 1111  C = 0

// C = 1
//     1111 1111
// +   0000 0001
// +   0000 0001  from C
// = 1 0000 0001  C = 1

// C = 1
//     1111 1111
// +   1111 1111
// +   0000 0001  from C
// = 1 1111 1111  C = 1

void ADC_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t AC = vm.read(SFR::AC);
    const uint8_t carry = vm.readFlag(SFlags::C);
    const uint16_t V = static_cast<uint16_t>(AC) +
                       static_cast<uint16_t>(param) +
                       static_cast<uint16_t>(carry);

    const auto result = static_cast<uint8_t>(V & 0x00FF);

    // Overflow: set if sign bit is incorrect (both operands same sign, result different)
    const bool overflow = (~(AC ^ param) & (AC ^ result) & 0x80) != 0;

    vm.write(SFR::AC, result);
    vm.writeFlag(SFlags::C, (V & 0x0100) != 0);
    vm.writeFlag(SFlags::Z, result == 0);
    vm.writeFlag(SFlags::N, (result & 0x80) != 0);
    vm.writeFlag(SFlags::V, overflow);
}

INSTRUCTION(ADC_immediate_oper, 0x69, 2)
{
    ADC_common(vm, p.two8s.p1);
}

INSTRUCTION(ADC_zero_page_oper, 0x65, 2)
{
    ADC_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(ADC_zero_page_oper_X, 0x75, 2)
{
    ADC_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(ADC_absolute_oper, 0x6D, 3)
{
    ADC_common(vm, vm.readData(p.one16));
}

INSTRUCTION(ADC_absolute_oper_X, 0x7D, 3)
{
    ADC_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(ADC_absolute_oper_Y, 0x79, 3)
{
    ADC_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(ADC_indirect_oper_X, 0x61, 2)
{
    /*
    This is a mixture of indexed addressing and indirect addressing, which can only be used with the X
register. It can be summarised as 'Add the offset and then find the address".
The operand is a 1 byte zero page address. The contents of the X register are added to it, and the resulting location will contain the least significant byte of a 2 byte address, which contains the data.
For example:
     */

    ADC_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(ADC_indirect_oper_Y, 0x71, 2)
{
    /*
     This is also a mixture of indexed and indirect addressing, but this one can only be used with the Y
register. It can be summarised as "Find the address and then add the offset."
The operand is a 1 byte zero page address, which contains the least significant byte of a 2 byte address.
The most significant byte is held in the next byte (aa+ 1).
To that 2 byte address, add the
contents of the Y register. The resulting address contains the data. For example, if we assume that
     */

    ADC_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// AND        and (with accumulator)

void AND_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint16_t V = vm.read(SFR::AC) & param;
    vm.write(SFR::AC, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(AND_immediate_oper, 0x29, 2)
{
    AND_common(vm, p.two8s.p1);
}

INSTRUCTION(AND_zero_page_oper, 0x25, 2)
{
    AND_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(AND_zero_page_oper_X, 0x35, 2)
{
    AND_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(AND_absolute_oper, 0x2D, 3)
{
    AND_common(vm, vm.readData(p.one16));
}

INSTRUCTION(AND_absolute_oper_X, 0x3D, 3)
{
    AND_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(AND_absolute_oper_Y, 0x39, 3)
{
    AND_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(AND_indirect_oper_X, 0x21, 2)
{
    AND_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(AND_indirect_oper_Y, 0x31, 2)
{
    AND_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// ASL        arithmetic shift left

void ASL_common(VirtualMachine& virtualMachine, uint8_t& value)
{
    const uint8_t C = (value & 0x80) >> 7;
    value <<= 1;

    vm.writeFlag(SFlags::C, C != 0);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(ASL_A, 0x0A, 1)
{
    uint8_t AC = vm.read(SFR::AC);
    ASL_common(vm, AC);
    vm.write(SFR::AC, AC);
}

INSTRUCTION(ASL_zero_page_oper, 0x06, 2)
{
    uint8_t value = vm.readZeroPage(p.two8s.p1);
    ASL_common(vm, value);
    vm.writeZeroPage(p.two8s.p1, value);
}

INSTRUCTION(ASL_zero_page_oper_X, 0x16, 2)
{
    const uint8_t addr = p.two8s.p1 + vm.read(SFR::X);
    uint8_t value = vm.readZeroPage(addr);
    ASL_common(vm, value);
    vm.writeZeroPage(addr, value);
}

INSTRUCTION(ASL_absolute_oper, 0x0E, 3)
{
    uint8_t value = vm.readData(p.one16);
    ASL_common(vm, value);
    vm.writeData(p.one16, value);
}

INSTRUCTION(ASL_absolute_oper_X, 0x1E, 3)
{
    const uint16_t addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t value = vm.readData(addr);
    ASL_common(vm, value);
    vm.writeData(addr, value);
}

// BCC        branch on carry clear

INSTRUCTION_NO_MOVE_NEXT(BCC_relative_oper, 0x90, 2)
{
    if (vm.readFlag(SFlags::C) == 0)
    {
        BCC_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BCC_relative_oper_definition.moveToNext(vm);
    }
}

// BCS        branch on carry set

INSTRUCTION_NO_MOVE_NEXT(BCS_relative_oper, 0xB0, 2)
{
    if (vm.readFlag(SFlags::C) != 0)
    {
        BCS_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BCS_relative_oper_definition.moveToNext(vm);
    }
}

// BEQ        branch on equal (zero set)

INSTRUCTION_NO_MOVE_NEXT(BEQ_relative_oper, 0xF0, 2)
{
    if (vm.readFlag(SFlags::Z) != 0)
    {
        BEQ_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BEQ_relative_oper_definition.moveToNext(vm);
    }
}

// BIT        bit test

void BIT_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t AC = vm.read(SFR::AC);
    const uint8_t result = AC & param;

    vm.writeFlag(SFlags::Z, result == 0);
    vm.writeFlag(SFlags::V, (param & 0x40) != 0);  // Bit 6 of memory
    vm.writeFlag(SFlags::N, (param & 0x80) != 0);  // Bit 7 of memory
}

INSTRUCTION(BIT_zero_page_oper, 0x24, 2)
{
    BIT_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(BIT_absolute_oper, 0x2C, 3)
{
    BIT_common(vm, vm.readData(p.one16));
}

// BMI        branch on minus (negative set)

INSTRUCTION_NO_MOVE_NEXT(BMI_relative_oper, 0x30, 2)
{
    if (vm.readFlag(SFlags::N) != 0)
    {
        BMI_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BMI_relative_oper_definition.moveToNext(vm);
    }
}

// BNE        branch on not equal (zero clear)

INSTRUCTION_NO_MOVE_NEXT(BNE_relative_oper, 0xD0, 2)
{
    if (vm.readFlag(SFlags::Z) == 0)
    {
        BNE_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BNE_relative_oper_definition.moveToNext(vm);
    }
}

// BPL        branch on plus (negative clear)

INSTRUCTION_NO_MOVE_NEXT(BPL_relative_oper, 0x10, 2)
{
    if (vm.readFlag(SFlags::N) == 0)
    {
        BPL_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BPL_relative_oper_definition.moveToNext(vm);
    }
}

// BRK        break / interrupt

INSTRUCTION(BRK, 0x00, 1)
{
}

// BVC        branch on overflow clear

INSTRUCTION_NO_MOVE_NEXT(BVC_relative_oper, 0x50, 2)
{
    if (vm.readFlag(SFlags::V) == 0)
    {
        BVC_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BVC_relative_oper_definition.moveToNext(vm);
    }
}

// BVS        branch on overflow set

INSTRUCTION_NO_MOVE_NEXT(BVS_relative_oper, 0x70, 2)
{
    if (vm.readFlag(SFlags::V) != 0)
    {
        BVS_relative_oper_definition.moveToRelativeJumpAddress(vm, instruction);
    }
    else
    {
        BVS_relative_oper_definition.moveToNext(vm);
    }
}

// CLC        clear carry

INSTRUCTION(CLC, 0x18, 1)
{
    vm.writeFlag(SFlags::C, false);
}

// CLD        clear decimal

INSTRUCTION(CLD, 0xD8, 1)
{
    vm.writeFlag(SFlags::D, false);
}

// CLI        clear interrupt disable

INSTRUCTION(CLI, 0x58, 1)
{
    vm.writeFlag(SFlags::I, false);
}

// CLV        clear overflow

INSTRUCTION(CLV, 0xB8, 1)
{
    vm.writeFlag(SFlags::V, false);
}

// CMP        compare (with accumulator)

void CMP_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t AC = vm.read(SFR::AC);
    const bool lte = param <= AC;
    const uint16_t V = AC - param;

    vm.writeFlag(SFlags::C, lte);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(CMP_immediate_oper, 0xC9, 2)
{
    CMP_common(vm, p.two8s.p1);
}

INSTRUCTION(CMP_zero_page_oper, 0xC5, 2)
{
    CMP_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(CMP_zero_page_oper_X, 0xD5, 2)
{
    CMP_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(CMP_absolute_oper, 0xCD, 3)
{
    CMP_common(vm, vm.readData(p.one16));
}

INSTRUCTION(CMP_absolute_oper_X, 0xDD, 3)
{
    CMP_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(CMP_absolute_oper_Y, 0xD9, 3)
{
    CMP_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(CMP_indirect_oper_X, 0xC1, 2)
{
    CMP_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(CMP_indirect_oper_Y, 0xD1, 2)
{
    CMP_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// CPX        compare with X

void CPX_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t X = vm.read(SFR::X);
    const bool lte = param <= X;
    const uint16_t V = X - param;

    vm.writeFlag(SFlags::C, lte);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(CPX_immediate_oper, 0xE0, 2)
{
    CPX_common(vm, p.two8s.p1);
}

INSTRUCTION(CPX_zeropage_oper, 0xE4, 2)
{
    CPX_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(CPX_absolute_oper, 0xEC, 3)
{
    CPX_common(vm, vm.readData(p.one16));
}

// CPY        compare with Y

void CPY_common(VirtualMachine& virtualMachine, uint8_t param)
{
    const uint8_t Y = vm.read(SFR::Y);
    const bool lte = param <= Y;
    const uint16_t V = Y - param;

    vm.writeFlag(SFlags::C, lte);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(CPY_immediate_oper, 0xC0, 2)
{
    CPY_common(vm, p.two8s.p1);
}

INSTRUCTION(CPY_zeropage_oper, 0xC4, 2)
{
    CPY_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(CPY_absolute_oper, 0xCC, 3)
{
    CPY_common(vm, vm.readData(p.one16));
}

// DEC        decrement

INSTRUCTION(DEC_absolute_oper, 0xCE, 3)
{
    uint8_t V = vm.readData(p.one16);
    V--;
    vm.writeData(p.one16, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(DEC_absolute_oper_x, 0xDE, 3)
{
    const auto addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t V = vm.readData(addr);
    V--;
    vm.writeData(addr, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(DEC_zero_page, 0xC6, 2)
{
    uint8_t V = vm.readData(static_cast<uint16_t>(p.two8s.p1));
    V--;
    vm.writeData(static_cast<uint16_t>(p.two8s.p1), V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(DEC_zero_page_oper_x, 0xD6, 2)
{
    const auto addr = static_cast<uint16_t>(p.two8s.p1 + vm.read(SFR::X)); // wrap in 8 bits
    uint8_t V = vm.readData(addr);
    V--;
    vm.writeData(addr, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// DEX        decrement X

INSTRUCTION(DEX, 0xCA, 1)
{
    uint8_t V = vm.read(SFR::X);
    V--;
    vm.write(SFR::X, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// DEY        decrement Y

INSTRUCTION(DEY, 0x88, 1)
{
    uint8_t V = vm.read(SFR::Y);
    V--;
    vm.write(SFR::Y, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// EOR        exclusive or (with accumulator)

void EOR_common(VirtualMachine& virtualMachine, uint8_t param)
{
    const uint8_t result = vm.read(SFR::AC) ^ param;

    vm.write(SFR::AC, result);
    vm.writeFlag(SFlags::Z, result == 0);
    vm.writeFlag(SFlags::N, (result & 0x80) != 0);
}

INSTRUCTION(EOR_immediate, 0x49, 2)
{
    EOR_common(vm, p.two8s.p1);
}

INSTRUCTION(EOR_absolute_oper, 0x4D, 3)
{
    EOR_common(vm, vm.readData(p.one16));
}

INSTRUCTION(EOR_absolute_oper_x, 0x5D, 3)
{
    EOR_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(EOR_absolute_oper_y, 0x59, 3)
{
    EOR_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(EOR_zero_page_oper, 0x45, 2)
{
    EOR_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(EOR_zero_page_oper_x, 0x55, 2)
{
    EOR_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(EOR_zero_page_indirect_x, 0x41, 2)
{
    EOR_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(EOR_zero_page_indirect_y, 0x51, 2)
{
    EOR_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// INC        increment

INSTRUCTION(INC_absolute_oper, 0xEE, 3)
{
    uint8_t V = vm.readData(p.one16);
    V++;
    vm.writeData(p.one16, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(INC_absolute_oper_x, 0xFE, 3)
{
    const auto addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t V = vm.readData(addr);
    V++;
    vm.writeData(addr, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(INC_zero_page_oper, 0xE6, 2)
{
    uint8_t V = vm.readData(static_cast<uint16_t>(p.two8s.p1));
    V++;
    vm.writeData(static_cast<uint16_t>(p.two8s.p1), V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(INC_zero_page_oper_x, 0xF6, 2)
{
    const auto addr = static_cast<uint16_t>(p.two8s.p1 + vm.read(SFR::X)); // wrap in 8 bits
    uint8_t V = vm.readData(addr);
    V++;
    vm.writeData(addr, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// INX        increment X

INSTRUCTION(INX, 0xE8, 1)
{
    uint8_t V = vm.read(SFR::X);
    V++;
    vm.write(SFR::X, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// INY        increment Y

INSTRUCTION(INY, 0xC8, 1)
{
    uint8_t V = vm.read(SFR::Y);
    V++;
    vm.write(SFR::Y, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// JMP        jump

INSTRUCTION_NO_MOVE_NEXT(JMP_absolute, 0x4C, 3)
{
    vm.write(SFR16::PC, p.one16);
}

INSTRUCTION_NO_MOVE_NEXT(JMP_absolute_indirect, 0x6C, 3)
{
    vm.write(SFR16::PC, vm.readData16(p.one16));
}

// JSR        jump subroutine

INSTRUCTION_NO_MOVE_NEXT(JSR_absolute, 0x20, 3)
{
    const uint16_t returnAddr = vm.read(SFR16::PC) + 2;
    vm.pushByte((returnAddr & 0xFF00) >> 8);  // Push high byte first
    vm.pushByte(returnAddr & 0x00FF);          // Then low byte
    vm.write(SFR16::PC, p.one16);
}

// LDA        load accumulator

void LDA_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    vm.write(SFR::AC, param);
    vm.writeFlag(SFlags::Z, param == 0);
    vm.writeFlag(SFlags::N, (param & (1 << 7)) != 0);
}

INSTRUCTION(LDA_immediate_oper, 0xA9, 2)
{
    const auto V = p.two8s.p1;

    vm.write(SFR::AC, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

INSTRUCTION(LDA_absolute_oper, 0xAD, 3)
{
    LDA_common(vm, vm.readData(p.one16));
}

INSTRUCTION(LDA_absolute_oper_X, 0xBD, 3)
{
    LDA_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(LDA_absolute_oper_Y, 0xB9, 3)
{
    LDA_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(LDA_zero_page_oper, 0xA5, 2)
{
    LDA_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(LDA_zero_page_oper_X, 0xB5, 2)
{
    LDA_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(LDA_indirect_oper_X, 0xA1, 2)
{
    LDA_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(LDA_indirect_oper_Y, 0xB1, 2)
{
    LDA_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// LDX        load X

INSTRUCTION(LDX_immediate, 0xA2, 2)
{
    vm.write(SFR::X, p.two8s.p1);
    vm.writeFlag(SFlags::Z, p.two8s.p1 == 0);
    vm.writeFlag(SFlags::N, (p.two8s.p1 & (1 << 7)) != 0);
}

INSTRUCTION(LDX_zero_page, 0xA6, 2)
{
    const uint8_t value = vm.readZeroPage(p.two8s.p1);
    vm.write(SFR::X, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDX_zero_page_Y, 0xB6, 2)
{
    const uint8_t value = vm.readZeroPage(p.two8s.p1 + vm.read(SFR::Y));
    vm.write(SFR::X, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDX_absolute, 0xAE, 3)
{
    const uint8_t value = vm.readData(p.one16);
    vm.write(SFR::X, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDX_absolute_Y, 0xBE, 3)
{
    const uint8_t value = vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y)));
    vm.write(SFR::X, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

// LDY        load Y

INSTRUCTION(LDY_immediate, 0xA0, 2)
{
    vm.write(SFR::Y, p.two8s.p1);
    vm.writeFlag(SFlags::Z, p.two8s.p1 == 0);
    vm.writeFlag(SFlags::N, (p.two8s.p1 & (1 << 7)) != 0);
}

INSTRUCTION(LDY_zero_page, 0xA4, 2)
{
    const uint8_t value = vm.readZeroPage(p.two8s.p1);
    vm.write(SFR::Y, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDY_zero_page_X, 0xB4, 2)
{
    const uint8_t value = vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X));
    vm.write(SFR::Y, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDY_absolute, 0xAC, 3)
{
    const uint8_t value = vm.readData(p.one16);
    vm.write(SFR::Y, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

INSTRUCTION(LDY_absolute_X, 0xBC, 3)
{
    const uint8_t value = vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X)));
    vm.write(SFR::Y, value);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, (value & 0x80) != 0);
}

// LSR        logical shift right

void LSR_common(VirtualMachine& virtualMachine, uint8_t& value)
{
    const uint8_t C = value & 0x01;
    value >>= 1;

    vm.writeFlag(SFlags::C, C != 0);
    vm.writeFlag(SFlags::Z, value == 0);
    vm.writeFlag(SFlags::N, false);  // Bit 7 is always 0 after LSR
}

INSTRUCTION(LSR_A, 0x4A, 1)
{
    uint8_t AC = vm.read(SFR::AC);
    LSR_common(vm, AC);
    vm.write(SFR::AC, AC);
}

INSTRUCTION(LSR_zero_page_oper, 0x46, 2)
{
    uint8_t value = vm.readZeroPage(p.two8s.p1);
    LSR_common(vm, value);
    vm.writeZeroPage(p.two8s.p1, value);
}

INSTRUCTION(LSR_zero_page_oper_X, 0x56, 2)
{
    const uint8_t addr = p.two8s.p1 + vm.read(SFR::X);
    uint8_t value = vm.readZeroPage(addr);
    LSR_common(vm, value);
    vm.writeZeroPage(addr, value);
}

INSTRUCTION(LSR_absolute_oper, 0x4E, 3)
{
    uint8_t value = vm.readData(p.one16);
    LSR_common(vm, value);
    vm.writeData(p.one16, value);
}

INSTRUCTION(LSR_absolute_oper_X, 0x5E, 3)
{
    const uint16_t addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t value = vm.readData(addr);
    LSR_common(vm, value);
    vm.writeData(addr, value);
}

// NOP        no operation

INSTRUCTION(NOP, 0xEA, 1)
{
}

// ORA        or with accumulator

void ORA_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t result = vm.read(SFR::AC) | param;

    vm.write(SFR::AC, result);
    vm.writeFlag(SFlags::Z, result == 0);
    vm.writeFlag(SFlags::N, (result & 0x80) != 0);
}

INSTRUCTION(ORA_immediate_oper, 0x09, 2)
{
    ORA_common(vm, p.two8s.p1);
}

INSTRUCTION(ORA_zero_page_oper, 0x05, 2)
{
    ORA_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(ORA_zero_page_oper_X, 0x15, 2)
{
    ORA_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(ORA_absolute_oper, 0x0D, 3)
{
    ORA_common(vm, vm.readData(p.one16));
}

INSTRUCTION(ORA_absolute_oper_X, 0x1D, 3)
{
    ORA_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(ORA_absolute_oper_Y, 0x19, 3)
{
    ORA_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(ORA_indirect_oper_X, 0x01, 2)
{
    ORA_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(ORA_indirect_oper_Y, 0x11, 2)
{
    ORA_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// PHA        push accumulator

INSTRUCTION(PHA, 0x48, 1)
{
    vm.pushByte(vm.read(SFR::AC));
}

// PHP        push processor status (SR)

INSTRUCTION(PHP, 0x08, 1)
{
    vm.pushByte(vm.read(SFR::SR));
}

// PLA        pull accumulator

INSTRUCTION(PLA, 0x68, 1)
{
    const uint8_t V = vm.popByte();
    vm.write(SFR::AC, V);
    vm.writeFlag(SFlags::Z, V == 0);
    vm.writeFlag(SFlags::N, (V & (1 << 7)) != 0);
}

// PLP        pull processor status (SR)

INSTRUCTION(PLP, 0x28, 1)
{
    vm.write(SFR::SR, vm.popByte());
}

// ROL        rotate left

void ROL_common(VirtualMachine& virtualMachine, uint8_t& V)
{
    uint8_t SR = vm.read(SFR::SR);

    uint8_t C = SR & static_cast<uint8_t>(SFlags::C);

    const uint8_t msb = (V & (1 << 7)) >> 7;
    V <<= 1;
    V |= C;

    C = msb;
    SR &= ~static_cast<uint8_t>(SFlags::C);
    SR |= C;

    vm.write(SFR::SR, SR);
}

INSTRUCTION(ROL_A, 0x2A, 1)
{
    uint8_t AC = vm.read(SFR::AC);
    ROL_common(vm, AC);
    virtualMachine.write(SFR::AC, AC);
}

INSTRUCTION(ROL_oper_zero_page, 0x26, 2)
{
    uint8_t V = vm.readZeroPage(p.two8s.p1);
    ROL_common(vm, V);
    vm.writeZeroPage(p.two8s.p1, V);
}

INSTRUCTION(ROL_oper_zero_page_X, 0x36, 2)
{
    const uint8_t O = p.two8s.p1 + vm.read(SFR::X);
    uint8_t V = vm.readZeroPage(O);
    ROL_common(vm, V);
    vm.writeZeroPage(O, V);
}

INSTRUCTION(ROL_oper_abs, 0x2E, 3)
{
    uint8_t V = vm.readData(p.one16);
    ROL_common(vm, V);
    vm.writeData(p.one16, V);
}

INSTRUCTION(ROL_oper_abs_X, 0x3E, 3)
{
    const auto addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t V = vm.readData(addr);
    ROL_common(vm, V);
    vm.writeData(addr, V);
}

// ROR        rotate right

void ROR_common(VirtualMachine& virtualMachine, uint8_t& V)
{
    uint8_t SR = vm.read(SFR::SR);

    uint8_t C = SR & static_cast<uint8_t>(SFlags::C);

    const uint8_t lsb = V & 0x01;
    V >>= 1;
    V |= (C << 7);

    C = lsb;
    SR &= ~static_cast<uint8_t>(SFlags::C);
    SR |= C;

    vm.write(SFR::SR, SR);
}
INSTRUCTION(ROR_A, 0x6A, 1)
{
    uint8_t AC = virtualMachine.read(SFR::AC);
    ROR_common(vm, AC);
    virtualMachine.write(SFR::AC, AC);
}

INSTRUCTION(ROR_oper_zero_page, 0x66, 2)
{
    uint8_t V = vm.readZeroPage(p.two8s.p1);
    ROR_common(vm, V);
    vm.writeZeroPage(p.two8s.p1, V);
}

INSTRUCTION(ROR_oper_zero_page_X, 0x76, 2)
{
    const uint8_t O = p.two8s.p1 + vm.read(SFR::X);
    uint8_t V = vm.readZeroPage(O);
    ROR_common(vm, V);
    vm.writeZeroPage(O, V);
}

INSTRUCTION(ROR_oper_abs, 0x6E, 3)
{
    uint8_t V = vm.readData(p.one16);
    ROR_common(vm, V);
    vm.writeData(p.one16, V);
}

INSTRUCTION(ROR_oper_abs_X, 0x7E, 3)
{
    const auto addr = p.one16 + static_cast<uint16_t>(vm.read(SFR::X));
    uint8_t V = vm.readData(addr);
    ROR_common(vm, V);
    vm.writeData(addr, V);
}

// RTI        return from interrupt

INSTRUCTION_NO_MOVE_NEXT(RTI, 0x40, 1)
{
    // pulls the processor flags from the stack followed by the program counter.
    const uint8_t SR = vm.popByte();
    const uint16_t PC = static_cast<uint16_t>(vm.popByte()) | (static_cast<uint16_t>(vm.popByte()) << 8);

    vm.write(SFR::SR, SR);
    vm.write(SFR16::PC, PC);
}

// RTS        return from subroutine

INSTRUCTION_NO_MOVE_NEXT(RTS, 0x60, 1)
{
    //  loads the program count low and program count high from the stack into
    //  the program counter and increments the program counter so that it points
    //  to the instruction following the JSR
    const uint8_t low = vm.popByte();   // Pop low byte first
    const uint8_t high = vm.popByte();  // Then high byte
    uint16_t PC = (static_cast<uint16_t>(high) << 8) | static_cast<uint16_t>(low);
    PC += 1;
    vm.write(SFR16::PC, PC);
}

// SBC        subtract with carry

void SBC_common(VirtualMachine& virtualMachine, const uint8_t param)
{
    const uint8_t AC = vm.read(SFR::AC);
    const uint8_t carry = vm.readFlag(SFlags::C);

    // SBC subtracts with borrow (inverted carry)
    const uint16_t V = static_cast<uint16_t>(AC) -
                       static_cast<uint16_t>(param) -
                       static_cast<uint16_t>(1 - carry);

    const auto result = static_cast<uint8_t>(V & 0x00FF);

    // Overflow: set if sign bit is incorrect
    const bool overflow = ((AC ^ param) & (AC ^ result) & 0x80) != 0;

    vm.write(SFR::AC, result);
    vm.writeFlag(SFlags::C, (V & 0x0100) == 0);  // Carry clear if borrow occurred
    vm.writeFlag(SFlags::Z, result == 0);
    vm.writeFlag(SFlags::N, (result & 0x80) != 0);
    vm.writeFlag(SFlags::V, overflow);
}

INSTRUCTION(SBC_immediate_oper, 0xE9, 2)
{
    SBC_common(vm, p.two8s.p1);
}

INSTRUCTION(SBC_zero_page_oper, 0xE5, 2)
{
    SBC_common(vm, vm.readZeroPage(p.two8s.p1));
}

INSTRUCTION(SBC_zero_page_oper_X, 0xF5, 2)
{
    SBC_common(vm, vm.readZeroPage(p.two8s.p1 + vm.read(SFR::X)));
}

INSTRUCTION(SBC_absolute_oper, 0xED, 3)
{
    SBC_common(vm, vm.readData(p.one16));
}

INSTRUCTION(SBC_absolute_oper_X, 0xFD, 3)
{
    SBC_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X))));
}

INSTRUCTION(SBC_absolute_oper_Y, 0xF9, 3)
{
    SBC_common(vm, vm.readData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y))));
}

INSTRUCTION(SBC_indirect_oper_X, 0xE1, 2)
{
    /*
    This is a mixture of indexed addressing and indirect addressing, which can only be used with the X
register. It can be summarised as 'Add the offset and then find the address".
The operand is a 1 byte zero page address. The contents of the X register are added to it, and the resulting location will contain the least significant byte of a 2 byte address, which contains the data.
For example:
     */

    SBC_common(vm, vm.readData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X)))));
}

INSTRUCTION(SBC_indirect_oper_Y, 0xF1, 2)
{
    /*
     This is also a mixture of indexed and indirect addressing, but this one can only be used with the Y
register. It can be summarised as "Find the address and then add the offset."
The operand is a 1 byte zero page address, which contains the least significant byte of a 2 byte address.
The most significant byte is held in the next byte (aa+ 1).
To that 2 byte address, add the
contents of the Y register. The resulting address contains the data. For example, if we assume that
     */

    SBC_common(vm, vm.readData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y))));
}

// SEC        set carry

INSTRUCTION(SEC, 0x38, 1)
{
    vm.writeFlag(SFlags::C, true);
}

// SED        set decimal

INSTRUCTION(SED, 0xF8, 1)
{
    vm.writeFlag(SFlags::D, true);
}

// SEI        set interrupt disable

INSTRUCTION(SEI, 0x78, 1)
{
    vm.writeFlag(SFlags::I, true);
}

// STA        store accumulator

INSTRUCTION(STA_zero_page, 0x85, 2)
{
    vm.writeZeroPage(p.two8s.p1, vm.read(SFR::AC));
}

INSTRUCTION(STA_zero_page_X, 0x95, 2)
{
    vm.writeZeroPage(p.two8s.p1 + vm.read(SFR::X), vm.read(SFR::AC));
}

INSTRUCTION(STA_absolute, 0x8D, 3)
{
    vm.writeData(p.one16, vm.read(SFR::AC));
}

INSTRUCTION(STA_absolute_X, 0x9D, 3)
{
    vm.writeData(p.one16 + static_cast<uint16_t>(vm.read(SFR::X)), vm.read(SFR::AC));
}

INSTRUCTION(STA_absolute_Y, 0x99, 3)
{
    vm.writeData(p.one16 + static_cast<uint16_t>(vm.read(SFR::Y)), vm.read(SFR::AC));
}

INSTRUCTION(STA_indirect_X, 0x81, 2)
{
    vm.writeData(vm.readData16(p.two8s.p1 + static_cast<uint16_t>(vm.read(SFR::X))), vm.read(SFR::AC));
}

INSTRUCTION(STA_indirect_Y, 0x91, 2)
{
    vm.writeData(vm.readData16(p.two8s.p1) + static_cast<uint16_t>(vm.read(SFR::Y)), vm.read(SFR::AC));
}

// STX        store X

INSTRUCTION(STX_zero_page, 0x86, 2)
{
    vm.writeZeroPage(p.two8s.p1, vm.read(SFR::X));
}

INSTRUCTION(STX_zero_page_Y, 0x96, 2)
{
    vm.writeZeroPage(p.two8s.p1 + vm.read(SFR::Y), vm.read(SFR::X));
}

INSTRUCTION(STX_absolute, 0x8E, 3)
{
    vm.writeData(p.one16, vm.read(SFR::X));
}

// STY        store Y

INSTRUCTION(STY_zero_page, 0x84, 2)
{
    vm.writeZeroPage(p.two8s.p1, vm.read(SFR::Y));
}

INSTRUCTION(STY_zero_page_X, 0x94, 2)
{
    vm.writeZeroPage(p.two8s.p1 + vm.read(SFR::X), vm.read(SFR::Y));
}

INSTRUCTION(STY_absolute, 0x8C, 3)
{
    vm.writeData(p.one16, vm.read(SFR::Y));
}

// TAX        transfer accumulator to X

INSTRUCTION(TAX, 0xAA, 1)
{
    const uint8_t AC = vm.read(SFR::AC);
    vm.write(SFR::X, AC);
    vm.writeFlag(SFlags::N, ((AC & (1 << 7)) >> 7) != 0);
    vm.writeFlag(SFlags::Z, AC == 0);
}

// TAY        transfer accumulator to Y

INSTRUCTION(TAY, 0xA8, 1)
{
    const uint8_t AC = vm.read(SFR::AC);
    vm.write(SFR::Y, AC);
    vm.writeFlag(SFlags::N, ((AC & (1 << 7)) >> 7) != 0);
    vm.writeFlag(SFlags::Z, AC == 0);
}

// TSX        transfer stack pointer to X

INSTRUCTION(TSX, 0xBA, 1)
{
    const uint8_t SP = vm.read(SFR::SP);
    vm.write(SFR::X, SP);
    vm.writeFlag(SFlags::N, ((SP & (1 << 7)) >> 7) != 0);
    vm.writeFlag(SFlags::Z, SP == 0);
}

// TXA        transfer X to accumulator

INSTRUCTION(TXA, 0x8A, 1)
{
    const uint8_t X = vm.read(SFR::X);
    vm.write(SFR::AC, X);
    vm.writeFlag(SFlags::N, ((X & (1 << 7)) >> 7) != 0);
    vm.writeFlag(SFlags::Z, X == 0);
}

// TXS        transfer X to stack pointer

INSTRUCTION(TXS, 0x9A, 1)
{
    vm.write(SFR::SP, vm.read(SFR::X));
}

// TYA        transfer Y to accumulator

INSTRUCTION(TYA, 0x98, 1)
{
    const uint8_t Y = vm.read(SFR::Y);
    vm.write(SFR::AC, Y);
    vm.writeFlag(SFlags::N, ((Y & (1 << 7)) >> 7) != 0);
    vm.writeFlag(SFlags::Z, Y == 0);
}
