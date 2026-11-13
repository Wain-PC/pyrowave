# Builds the Metal port and the pwmetal command line harness.
cmake_minimum_required(VERSION 3.20)
project(pyrowave-metal-harness LANGUAGES CXX C OBJCXX)

set(CMAKE_CXX_STANDARD 17)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/.." pyrowave-metal)

add_executable(pwmetal pwmetal.mm)
target_compile_options(pwmetal PRIVATE -fobjc-arc -Wall -Wextra)
target_include_directories(pwmetal PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(pwmetal PRIVATE pyrowave-metal
		"-framework Foundation" "-framework Metal" "-framework CoreVideo" "-framework IOSurface")
