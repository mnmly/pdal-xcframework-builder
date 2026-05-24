# iOS device (iphoneos) arm64 toolchain.
# Used by build_e57.sh and build.sh's iOS slice configures, plus the
# per-dep cross-compile scripts under scripts/deps/.
#
# Keep the deployment target aligned with gdal-xcframework-builder's
# iOS toolchain — drift causes Mach-O LC_BUILD_VERSION mismatches that
# xcodebuild -create-xcframework will accept but consumers will reject.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)

# Cross-compile root-path rules: programs (cmake, perl, etc.) must be
# resolved on the host, but headers/libraries/packages must be resolved
# against the iOS sysroot + CMAKE_PREFIX_PATH only.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Pre-cache try_run answers that fail in cross-compile. iOS arm64 is
# little-endian, IEEE-754. Add more as deps demand them.
set(HAVE_BIG_ENDIAN 0 CACHE INTERNAL "")
set(WORDS_BIGENDIAN 0 CACHE INTERNAL "")
