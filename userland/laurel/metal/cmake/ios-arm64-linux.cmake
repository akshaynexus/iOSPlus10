# CMake toolchain: iOS 16.0 arm64 built on a Linux host (no Xcode, no xcrun). Used by scripts/laurel/metal-build.sh
# (NMTL_CMAKE_TOOLCHAIN) for userland/metal; on macOS scripts/metal/build.sh keeps userland/metal/cmake/ios-arm64.cmake.
# Compiler: the host clang with -target arm64-apple-ios16.0 (clang is a cross compiler for every target); linker:
# ld64.lld (LLVM's Mach-O linker); SDK: $SDK (iPhoneOS16.5.sdk, scripts/laurel/metal-env.sh).
include("${CMAKE_CURRENT_LIST_DIR}/../../../metal/cmake/ios-arm64.cmake")
if(NOT DEFINED ENV{SDK})
  message(FATAL_ERROR "set SDK to an iPhoneOS.sdk directory (scripts/laurel/metal-env.sh)")
endif()
# full paths: with CMAKE_SYSTEM_NAME iOS, CMake does not look up a bare OBJC/OBJCXX compiler name on PATH
find_program(NMTL_CLANG clang REQUIRED NO_CMAKE_FIND_ROOT_PATH)
find_program(NMTL_CLANGXX clang++ REQUIRED NO_CMAKE_FIND_ROOT_PATH)
set(CMAKE_C_COMPILER "${NMTL_CLANG}")
set(CMAKE_CXX_COMPILER "${NMTL_CLANGXX}")
set(CMAKE_OBJC_COMPILER "${NMTL_CLANG}")
set(CMAKE_OBJCXX_COMPILER "${NMTL_CLANGXX}")
foreach(lang C CXX OBJC OBJCXX)
  set(CMAKE_${lang}_COMPILER_TARGET "arm64-apple-ios${CMAKE_OSX_DEPLOYMENT_TARGET}")
  # Mi A3 (Kryo 260, ARMv8.0): scripts/laurel/metal-env.sh NMTL_CPU_FLAGS (-mcpu=cortex-a53 + A53 erratum fix)
  set(CMAKE_${lang}_FLAGS_INIT "$ENV{NMTL_CPU_FLAGS} $ENV{NMTL_EXTRA_FLAGS}")
endforeach()
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
find_program(CMAKE_AR llvm-ar REQUIRED NO_CMAKE_FIND_ROOT_PATH)
find_program(CMAKE_RANLIB llvm-ranlib REQUIRED NO_CMAKE_FIND_ROOT_PATH)
find_program(CMAKE_INSTALL_NAME_TOOL llvm-install-name-tool REQUIRED NO_CMAKE_FIND_ROOT_PATH)
# only the SDK, never the host's libraries or headers
set(CMAKE_FIND_ROOT_PATH "$ENV{SDK}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
