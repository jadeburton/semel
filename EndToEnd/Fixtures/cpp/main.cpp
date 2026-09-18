#include <iostream>
#include <fstream>
#include <thread>

#include "VirtualMachine.h"

int main()
{
    VirtualMachine virtualMachine;

    uint32_t offset = 0x8000; // TODO: read from file itself in future
//    std::array<uint8_t, 1024> buffer = { 0 };

    std::ifstream inputFile("a.out", std::ios::binary);

//    inputFile.seekg(127, std::ios_base::seekdir::beg);

    if (!inputFile.good()) {
        std::cout << "file empty or missing\n";
        return -1;
    }
    while (inputFile.good())
    {
        char ch;
        inputFile.get(ch);
        virtualMachine.writeCode(offset++, (uint8_t)ch);
    }

    virtualMachine.write(SFR16::PC, 0x8000);

    virtualMachine.run();

    return 0;
}
