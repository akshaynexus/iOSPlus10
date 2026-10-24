# NegroniMetal: Metal on the Adreno 730 through metal2vulkan + Turnip (docs/metal-design.md).
# Built by scripts/metal/build.sh (it passes the paths below); by hand:
#   cmake -S userland/metal -B out/metal/build -G Ninja -DCMAKE_TOOLCHAIN_FILE=userland/metal/cmake/ios-arm64.cmake \
#         -DNMTL_BRIDGE_LIB=out/metal/bridge/ios/libnative_metal_bridge.a -DNMTL_FLAME_SRC=out/metal/src/flame/phone/metal2
#   ninja -C out/metal/build
# Targets: vkprobe and metalprobe always; the plugin (NegroniMetal, a Mach-O bundle) and m2vtest when the bridge
# static library and the frontend sources exist.
cmake_minimum_required(VERSION 3.24)
project(NegroniMetal LANGUAGES C CXX OBJC OBJCXX)

set(NMTL_BRIDGE_LIB "" CACHE FILEPATH "libnative_metal_bridge.a (scripts/metal/build-bridge.sh)")
set(NMTL_FLAME_SRC "" CACHE PATH "ios-flame phone/metal2 exported by scripts/metal/fetch-sources.sh")
set(NMTL_CLASS "NegroniMTLDevice" CACHE STRING "principal class = kernel MetalPluginClassName")
set(VULKAN_INCLUDE "" CACHE PATH "directory holding vulkan/vulkan.h (Vulkan-Headers)")

if(NOT VULKAN_INCLUDE)
  foreach(c /opt/homebrew/include /usr/local/include /usr/include)
    if(EXISTS "${c}/vulkan/vulkan.h")
      set(VULKAN_INCLUDE "${c}")
      break()
    endif()
  endforeach()
endif()
if(NOT EXISTS "${VULKAN_INCLUDE}/vulkan/vulkan.h")
  message(FATAL_ERROR "vulkan/vulkan.h not found: brew install vulkan-headers (or apt install libvulkan-dev), or -DVULKAN_INCLUDE=")
endif()

# command-line tools, not .app bundles (CMake defaults MACOSX_BUNDLE to ON for iOS)
set(CMAKE_MACOSX_BUNDLE OFF)
set(common_warn -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations)

# ---- stage 0: Turnip probe (C; dlopens the ICD, so it builds without Turnip). Only the headers, not the host's libs.
add_executable(vkprobe probes/vkprobe.c)
target_compile_options(vkprobe PRIVATE ${common_warn} -O2 -idirafter "${VULKAN_INCLUDE}")

# ---- stages 1-3: Metal probe
add_executable(metalprobe probes/metalprobe.m)
target_compile_options(metalprobe PRIVATE ${common_warn} -O2 -fobjc-arc)
target_link_libraries(metalprobe PRIVATE "-framework Foundation" "-framework Metal" "-framework IOSurface"
  "-framework IOKit" "-framework CoreFoundation")

# ---- the plugin bundle
if(NMTL_BRIDGE_LIB AND EXISTS "${NMTL_BRIDGE_LIB}" AND EXISTS "${NMTL_FLAME_SRC}/NativeBridgeMetalFrontend.mm")
  add_library(NegroniMetal MODULE plugin/NegroniMetal.mm "${NMTL_FLAME_SRC}/NativeBridgeMetalFrontend.mm")
  set_target_properties(NegroniMetal PROPERTIES PREFIX "" SUFFIX "" OUTPUT_NAME NegroniMetal)
  target_include_directories(NegroniMetal PRIVATE "${NMTL_FLAME_SRC}")
  target_compile_definitions(NegroniMetal PRIVATE NMTL_CLASS=${NMTL_CLASS})
  target_compile_options(NegroniMetal PRIVATE -std=c++17 -fobjc-arc -O2 -g -Wall -Wno-deprecated-declarations
    -Wno-unused-function)
  target_link_options(NegroniMetal PRIVATE -Wl,-dead_strip)
  target_link_libraries(NegroniMetal PRIVATE "${NMTL_BRIDGE_LIB}" c++ "-framework Foundation" "-framework Metal"
    "-framework IOSurface" "-framework IOKit" "-framework CoreFoundation")

  # the bridge's own self-test (compute, render, IOSurface-style host import, QuartzCore translation) without Metal.framework
  add_executable(m2vtest "${NMTL_FLAME_SRC}/m2vtest.c")
  target_include_directories(m2vtest PRIVATE "${NMTL_FLAME_SRC}")
  target_link_options(m2vtest PRIVATE -Wl,-dead_strip)
  target_link_libraries(m2vtest PRIVATE "${NMTL_BRIDGE_LIB}" c++ "-framework Foundation" "-framework IOSurface"
    "-framework IOKit" "-framework CoreFoundation" "-framework Security")
else()
  message(STATUS "NegroniMetal plugin skipped: set NMTL_BRIDGE_LIB and NMTL_FLAME_SRC (scripts/metal/build.sh does)")
endif()
