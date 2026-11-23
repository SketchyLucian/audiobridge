cmake_minimum_required(VERSION 3.22)
project(audiobridge_native LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory("../../../../../third_party/opus-1.6.1" "opus")

add_library(audiobridge_opus SHARED opus_jni.cpp aaudio_output_jni.cpp)

target_link_libraries(audiobridge_opus PRIVATE Opus::opus log dl)
