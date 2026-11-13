# Builds upstream's Vulkan reference tools (encode.cpp / decode.cpp) without SDL, so
# the Metal port can be cross-checked against them on macOS through MoltenVK.
#
# Requires ./checkout_granite.sh to have been run in the repository root.
cmake_minimum_required(VERSION 3.20)
project(pyrowave-vkref LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_C_STANDARD 99)

get_filename_component(PYROWAVE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)

set(GRANITE_VULKAN_SHADER_MANAGER_RUNTIME_COMPILER OFF CACHE BOOL "" FORCE)
set(GRANITE_SHADER_COMPILER_OPTIMIZE OFF CACHE BOOL "" FORCE)
set(GRANITE_POSITION_INDEPENDENT ON CACHE BOOL "" FORCE)
set(GRANITE_SHIPPING OFF CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_SPIRV_CROSS OFF CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_SYSTEM_HANDLES OFF CACHE BOOL "" FORCE)
set(GRANITE_RENDERER OFF CACHE BOOL "" FORCE)
set(GRANITE_VULKAN_FOSSILIZE OFF CACHE BOOL "" FORCE)
set(GRANITE_AUDIO OFF CACHE BOOL "" FORCE)
set(GRANITE_BULLET OFF CACHE BOOL "" FORCE)
set(GRANITE_TOOLS OFF CACHE BOOL "" FORCE)
set(GRANITE_PLATFORM "null" CACHE STRING "" FORCE)

add_subdirectory("${PYROWAVE_ROOT}/Granite" granite EXCLUDE_FROM_ALL)
add_subdirectory("${PYROWAVE_ROOT}" pyrowave EXCLUDE_FROM_ALL)

add_granite_offline_tool(pyrowave-encode "${PYROWAVE_ROOT}/encode.cpp")
target_link_libraries(pyrowave-encode PRIVATE pyrowave granite-vulkan pyrowave-utils)

add_granite_offline_tool(pyrowave-decode "${PYROWAVE_ROOT}/decode.cpp")
target_link_libraries(pyrowave-decode PRIVATE pyrowave granite-vulkan pyrowave-utils)
