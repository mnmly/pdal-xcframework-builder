#!/bin/bash
# Cross-compile xerces-c statically for an iOS SDK.
#
# Usage:  XERCES_VERSION=3.3.0 \
#         ./scripts/deps/xerces-c.sh <device|simulator> <install_prefix>
#
# Idempotent: skips if ${install_prefix}/lib/libxerces-c.a already exists.
# Source clone is shared across slices at work/src-deps/xerces-c-<ver>/.
#
# Why a separate script:
# - build_e57.sh's macOS Phase 1 already builds xerces dynamically into a
#   sandbox prefix. iOS needs static + a different toolchain, so the
#   logic doesn't share well. Keeping iOS deps under scripts/deps/ also
#   matches gdal-xcframework-builder's structure.
set -euo pipefail

SDK="${1:-}"
PREFIX="${2:-}"

if [ -z "${SDK}" ] || [ -z "${PREFIX}" ]; then
    echo "Usage: $0 <device|simulator> <install_prefix>" >&2
    exit 2
fi
: "${XERCES_VERSION:?XERCES_VERSION must be set (e.g. 3.3.0)}"

case "${SDK}" in
    device)    TOOLCHAIN_FILE="ios-device.cmake" ;;
    simulator) TOOLCHAIN_FILE="ios-sim.cmake" ;;
    *) echo "unknown SDK '${SDK}' — expected 'device' or 'simulator'" >&2; exit 2 ;;
esac

# Locate builder root (this script lives at scripts/deps/).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLCHAIN="${ROOT}/scripts/toolchain/${TOOLCHAIN_FILE}"
[ -f "${TOOLCHAIN}" ] || { echo "toolchain not found: ${TOOLCHAIN}" >&2; exit 1; }

# Idempotent: if the static archive is already in place, exit.
if [ -f "${PREFIX}/lib/libxerces-c.a" ]; then
    echo "xerces-c (${SDK}) already built at ${PREFIX}"
    exit 0
fi

SRC_PARENT="${ROOT}/work/src-deps"
SRC_DIR="${SRC_PARENT}/xerces-c-${XERCES_VERSION}"
BUILD_DIR="${ROOT}/work/deps-build/xerces-c-${XERCES_VERSION}-ios-${SDK}"

mkdir -p "${SRC_PARENT}" "${PREFIX}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Shared shallow clone (matches macOS path).
if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "v${XERCES_VERSION}" \
        https://github.com/apache/xerces-c.git "${SRC_DIR}"
fi

# Configure. Flags mirror build_e57.sh's macOS path except:
#  - BUILD_SHARED_LIBS=OFF — static archive
#  - CMAKE_TOOLCHAIN_FILE — iOS sysroot + arch
#  - CMAKE_POSITION_INDEPENDENT_CODE=ON — needed because the .a will be
#    merged into another .a (libE57Format) that ends up in a framework
#    binary; PIC is required for iOS regardless.
#  - No -DCMAKE_IGNORE_PATH=/opt/homebrew — toolchain root-path rules
#    already exclude host package dirs.
#  - Network OFF, transcoder=iconv — same as macOS.
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -Dtranscoder=iconv \
    -Dnetwork=OFF \
    -Dthreads=ON \
    -DCMAKE_MACOSX_BUNDLE=OFF

cmake --build "${BUILD_DIR}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${BUILD_DIR}"

# Validate: must be arm64-only, must be tagged for the right SDK platform.
LIB="${PREFIX}/lib/libxerces-c.a"
[ -f "${LIB}" ] || { echo "missing ${LIB} after install" >&2; exit 1; }

ARCHS_OUT="$(lipo -archs "${LIB}" 2>/dev/null || true)"
if [ "${ARCHS_OUT}" != "arm64" ]; then
    echo "unexpected arch in ${LIB}: '${ARCHS_OUT}' (want arm64)" >&2
    exit 1
fi
echo "xerces-c (${SDK}) → ${LIB} (arm64)"
