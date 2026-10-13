cmake_minimum_required(VERSION 3.24)
project(TextPickerNative LANGUAGES C CXX)
if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  message(FATAL_ERROR "TextPicker native requires Apple Silicon macOS")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS" FORCE)
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Architecture" FORCE)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type")
# Do not embed developer checkout names/paths in shipped diagnostics or symbols.
get_filename_component(TEXTPICKER_SOURCE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
add_compile_options("-ffile-prefix-map=${TEXTPICKER_SOURCE_ROOT}=/TextPicker")
set(TEXT_PICKER_SANITIZER "" CACHE STRING "Optional address,undefined or thread")
if(TEXT_PICKER_SANITIZER AND NOT TEXT_PICKER_SANITIZER MATCHES "^(address,undefined|thread)$")
  message(FATAL_ERROR "Unsupported sanitizer")
endif()

# Deliberately pinned subset. geometry/flann are dependencies in OpenCV 5.
# Matching ARM HALs matter for bit-exact image interpolation.
set(BUILD_LIST "core,imgproc" CACHE STRING "OpenCV subset" FORCE)
foreach(flag BUILD_SHARED_LIBS BUILD_TESTS BUILD_PERF_TESTS BUILD_EXAMPLES BUILD_opencv_apps
             BUILD_JAVA BUILD_opencv_python3 WITH_OPENCL WITH_IPP WITH_ITT WITH_LAPACK
             WITH_PROTOBUF WITH_FFMPEG WITH_AVFOUNDATION WITH_COCOA WITH_UNIFONT WITH_JPEG
             WITH_OPENJPEG WITH_OPENEXR WITH_AVIF WITH_WEBP WITH_TIFF WITH_PNG CV_TRACE)
  set(${flag} OFF CACHE BOOL "Minimal native dependency" FORCE)
endforeach()
set(WITH_CAROTENE ON CACHE BOOL "Preserve ARM interpolation" FORCE)
set(WITH_KLEIDICV ON CACHE BOOL "Preserve ARM interpolation" FORCE)
set(OPENCV_DOWNLOAD_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../.build/deps/opencv-cache" CACHE PATH "Pinned cache" FORCE)
add_subdirectory(../.build/deps/opencv-5.0.0 opencv EXCLUDE_FROM_ALL)

add_library(textpicker_core STATIC
  src/buffer.cpp src/assets.cpp src/engine.cpp src/detector_ops.cpp src/preprocess.cpp src/geometry.cpp src/pipeline.cpp src/native_bridge.cpp
  models/recognizer.cpp models/detector.cpp ../.build/deps/clipper.cpp)
target_include_directories(textpicker_core PUBLIC src)
target_include_directories(textpicker_core PRIVATE ../.build/deps)
target_include_directories(textpicker_core SYSTEM PUBLIC
  ../.build/deps/opencv-5.0.0/modules/core/include ../.build/deps/opencv-5.0.0/modules/imgproc/include
  ../.build/deps/opencv-5.0.0/modules/geometry/include "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_definitions(textpicker_core PRIVATE ACCELERATE_NEW_LAPACK)
target_compile_options(textpicker_core PRIVATE -O3 -ffp-contract=off -Wall -Wextra -Werror
  -Wno-deprecated-declarations -fvisibility=hidden)
set_source_files_properties(../.build/deps/clipper.cpp PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-copy-with-user-provided-copy")
target_link_libraries(textpicker_core PUBLIC opencv_imgproc opencv_geometry opencv_flann opencv_core
  zlib tegra_hal kleidicv_hal kleidicv kleidicv_thread "-framework Accelerate")
if(TEXT_PICKER_SANITIZER)
  target_compile_options(textpicker_core PUBLIC -O1 -g -fno-omit-frame-pointer "-fsanitize=${TEXT_PICKER_SANITIZER}")
  target_link_options(textpicker_core PUBLIC "-fsanitize=${TEXT_PICKER_SANITIZER}")
else()
  target_compile_options(textpicker_core PRIVATE -flto=thin)
  target_link_options(textpicker_core PUBLIC -flto=thin -Wl,-dead_strip)
endif()

foreach(probe unit_tests pipeline_probe detector_probe order_probe boundary_tests model_bounds)
  add_executable(${probe} tests/${probe}.cpp)
  set_target_properties(${probe} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
  target_link_libraries(${probe} PRIVATE textpicker_core)
endforeach()
enable_testing()
add_test(NAME primitives COMMAND unit_tests)
add_test(NAME boundaries COMMAND boundary_tests "${CMAKE_CURRENT_SOURCE_DIR}/../.build/models/native")
add_test(NAME model_bounds COMMAND model_bounds "${CMAKE_CURRENT_SOURCE_DIR}/../.build/models/native")
set_tests_properties(primitives boundaries model_bounds PROPERTIES
  ENVIRONMENT "VECLIB_MAXIMUM_THREADS=4;TEXTPICKER_THREADS=4" TIMEOUT 60)

find_program(SWIFTC swiftc REQUIRED)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/DecodeProbe"
  COMMAND "${SWIFTC}" -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0
    -file-prefix-map "${TEXTPICKER_SOURCE_ROOT}=/TextPicker"
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/src/native_bridge.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/worker/ImageDecode.swift" "${CMAKE_CURRENT_SOURCE_DIR}/tests/DecodeProbe.swift"
    -framework ImageIO -framework CoreGraphics -o "${CMAKE_CURRENT_BINARY_DIR}/DecodeProbe"
  DEPENDS worker/ImageDecode.swift tests/DecodeProbe.swift src/native_bridge.h VERBATIM)
add_custom_target(decode_probe ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/DecodeProbe")

add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/ProtocolTests"
  COMMAND "${SWIFTC}" -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0
    -file-prefix-map "${TEXTPICKER_SOURCE_ROOT}=/TextPicker"
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/src/native_bridge.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/worker/ImageDecode.swift" "${CMAKE_CURRENT_SOURCE_DIR}/worker/Protocol.swift"
    "${CMAKE_CURRENT_SOURCE_DIR}/tests/ProtocolTests.swift"
    -framework ImageIO -framework CoreGraphics -o "${CMAKE_CURRENT_BINARY_DIR}/ProtocolTests"
  DEPENDS worker/ImageDecode.swift worker/Protocol.swift tests/ProtocolTests.swift src/native_bridge.h VERBATIM)
add_custom_target(protocol_tests ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/ProtocolTests")
add_test(NAME protocol COMMAND "${CMAKE_CURRENT_BINARY_DIR}/ProtocolTests")
set_tests_properties(protocol PROPERTIES TIMEOUT 10)

if(NOT TEXT_PICKER_SANITIZER)
  set(native_libraries textpicker_core opencv_imgproc opencv_geometry opencv_flann opencv_core
                       zlib tegra_hal kleidicv_hal kleidicv kleidicv_thread)
  set(archives)
  foreach(library IN LISTS native_libraries)
    list(APPEND archives "$<TARGET_FILE:${library}>")
  endforeach()
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/TextPickerNative"
    COMMAND "${SWIFTC}" -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0
      -file-prefix-map "${TEXTPICKER_SOURCE_ROOT}=/TextPicker"
      -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/src/native_bridge.h"
      "${CMAKE_CURRENT_SOURCE_DIR}/worker/ImageDecode.swift"
      "${CMAKE_CURRENT_SOURCE_DIR}/worker/Protocol.swift"
      "${CMAKE_CURRENT_SOURCE_DIR}/worker/NativeWorker.swift"
      ${archives} -Xlinker -lc++ -Xlinker -dead_strip -framework Accelerate -framework ImageIO
      -framework CoreGraphics -o "${CMAKE_CURRENT_BINARY_DIR}/TextPickerNative"
    COMMAND codesign --force --sign - "${CMAKE_CURRENT_BINARY_DIR}/TextPickerNative"
    DEPENDS ${native_libraries} worker/ImageDecode.swift worker/Protocol.swift worker/NativeWorker.swift
      src/native_bridge.h VERBATIM)
  add_custom_target(native_worker ALL DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/TextPickerNative")
endif()
