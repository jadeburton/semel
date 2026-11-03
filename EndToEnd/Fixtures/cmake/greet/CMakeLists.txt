add_library(greet STATIC greet.c)
target_include_directories(greet PUBLIC include)
target_compile_definitions(greet PRIVATE GREET_TIMES=2)
