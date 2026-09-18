//
// Created by Jade Burton on 20.12.25.
//

#pragma once

#define INSTRUCTION_ARGS const Instruction& instruction, VirtualMachine& virtualMachine

#define INSTRUCTION_RANGE_NO_MOVE_NEXT(opcode, min, max, bytes) static void opcode(INSTRUCTION_ARGS); \
                                                                static auto opcode ## _opcodes = OpCodeRange(min, max); \
                                                                static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode, nullptr, nullptr, nullptr, bytes); \
                                                                static void opcode(INSTRUCTION_ARGS)

#define INSTRUCTION_RANGE(opcode, min, max, bytes) static void opcode(INSTRUCTION_ARGS); \
                                                   static void opcode ## _without_move_next(INSTRUCTION_ARGS); \
                                                   static auto opcode ## _opcodes = OpCodeRange(min, max); \
                                                   static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode, nullptr, nullptr, nullptr, bytes); \
                                                   static void opcode(INSTRUCTION_ARGS) { opcode ## _without_move_next(instruction, virtualMachine); opcode ## _definition.moveToNext(virtualMachine); } \
                                                   static void opcode ## _without_move_next(INSTRUCTION_ARGS)

#define INSTRUCTION(opcode, value, bytes) INSTRUCTION_RANGE(opcode, value, value, bytes)

#define INSTRUCTION_NO_MOVE_NEXT(opcode, value, bytes) INSTRUCTION_RANGE_NO_MOVE_NEXT(opcode, value, value, bytes)

#define INSTRUCTION_RANGE_2CYCLES_NO_MOVE_NEXT(opcode, min, max, bytes) static void opcode ## _cycle0(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle1(INSTRUCTION_ARGS); \
                                                                        static auto opcode ## _opcodes = OpCodeRange(min, max); \
                                                                        static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode ## _cycle0, &opcode ## _cycle1, nullptr, nullptr, bytes);

#define INSTRUCTION_RANGE_3CYCLES_NO_MOVE_NEXT(opcode, min, max, bytes) static void opcode ## _cycle0(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle1(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle2(INSTRUCTION_ARGS); \
                                                                        static auto opcode ## _opcodes = OpCodeRange(min, max); \
                                                                        static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode ## _cycle0, &opcode ## _cycle1, &opcode ## _cycle2, nullptr, bytes);

#define INSTRUCTION_RANGE_4CYCLES_NO_MOVE_NEXT(opcode, min, max, bytes) static void opcode ## _cycle0(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle1(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle2(INSTRUCTION_ARGS); \
                                                                        static void opcode ## _cycle3(INSTRUCTION_ARGS); \
                                                                        static auto opcode ## _opcodes = OpCodeRange(min, max); \
                                                                        static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode ## _cycle0, &opcode ## _cycle1, &opcode ## _cycle2, &opcode ## _cycle3, bytes);

#define INSTRUCTION_2CYCLES_NO_MOVE_NEXT(opcode, value, bytes) INSTRUCTION_RANGE_2CYCLES_NO_MOVE_NEXT(opcode, value, value, bytes)
#define INSTRUCTION_3CYCLES_NO_MOVE_NEXT(opcode, value, bytes) INSTRUCTION_RANGE_3CYCLES_NO_MOVE_NEXT(opcode, value, value, bytes)
#define INSTRUCTION_4CYCLES_NO_MOVE_NEXT(opcode, value, bytes) INSTRUCTION_RANGE_4CYCLES_NO_MOVE_NEXT(opcode, value, value, bytes)

#define INSTRUCTION_GROUP_2CYCLES_NO_MOVE_NEXT(opcode, bytes, ...) static void opcode ## _cycle0(INSTRUCTION_ARGS); \
                                                                   static void opcode ## _cycle1(INSTRUCTION_ARGS); \
                                                                   static auto opcode ## _opcodes = OpCodeGroup({__VA_ARGS__}); \
                                                                   static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode ## _cycle0, &opcode ## _cycle1, nullptr, nullptr, bytes);

#define INSTRUCTION_GROUP_2CYCLESX(opcode, bytes, ...) static void opcode ## _cycle0(INSTRUCTION_ARGS); \
                                                      static void opcode ## _cycle1(INSTRUCTION_ARGS); \
                                                      static auto opcode ## _opcodes = OpCodeGroup({__VA_ARGS__}); \
                                                      static Instruction::InstructionDefinition opcode ## _definition = Instruction::InstructionDefinition(opcode ## _opcodes, # opcode, &opcode ## _cycle0, &opcode ## _cycle1, nullptr, nullptr, bytes);

