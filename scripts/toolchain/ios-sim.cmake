# iOS simulator (iphonesimulator) arm64 toolchain. Identical to
# ios-device.cmake except for the sysroot — simulator binaries on Apple
# Silicon are still arm64, distinguished by LC_BUILD_VERSION platform
# tag (use `vtool -show-build` to confirm).

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT iphonesimulator)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(HAVE_BIG_ENDIAN 0 CACHE INTERNAL "")
set(WORDS_BIGENDIAN 0 CACHE INTERNAL "")
