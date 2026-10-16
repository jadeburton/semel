# A CMake project as semel-cmake reads it (B-166): a static library in a subdirectory with
# a public include folder and a private define, and an executable over it. No formula is
# committed beside this file: the harness runs `semel-cmake` over the folder, which
# writes semel.fmla and semel.config from this file and greet/CMakeLists.txt, and then
# builds what they say. The procedural lines below are what the tool refuses, by line,
# and the rest still translates.
cmake_minimum_required(VERSION 3.16)
project(cmake-hello VERSION 1.0 LANGUAGES C)

find_package(Threads)
if(WIN32)
  add_definitions(-DON_WINDOWS)
endif()

add_subdirectory(greet)

add_executable(hello src/main.c)
target_link_libraries(hello PRIVATE greet)
install(TARGETS hello DESTINATION bin)
