#!/bin/bash
# Cross-compile libcurl statically for an iOS SDK.
#
# Usage:  CURL_VERSION=8.10.1 \
#         ./scripts/deps/curl.sh <device|simulator> <install_prefix>
#
# Why this exists: iOS SDK ships no libcurl (apps are expected to use
# NSURLSession / CFNetwork). But PDAL's arbiter eagerly constructs an
# HTTP Pool on startup, so unresolved curl symbols crash the app even
# for local-file pipelines. We cross-build a minimal libcurl
# (HTTPS via SecureTransport, no extras) and merge it into
# pdalcpp.framework's binary via ld -r alongside the vendor archives.
#
# Idempotent: skips if ${install_prefix}/lib/libcurl.a already exists.
# Source clone is shared across slices at work/src-deps/curl-<ver>/.
set -euo pipefail

SDK="${1:-}"
PREFIX="${2:-}"

if [ -z "${SDK}" ] || [ -z "${PREFIX}" ]; then
    echo "Usage: $0 <device|simulator> <install_prefix>" >&2
    exit 2
fi
: "${CURL_VERSION:?CURL_VERSION must be set (e.g. 8.10.1)}"

case "${SDK}" in
    device)    TOOLCHAIN_FILE="ios-device.cmake" ;;
    simulator) TOOLCHAIN_FILE="ios-sim.cmake" ;;
    *) echo "unknown SDK '${SDK}' — expected 'device' or 'simulator'" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLCHAIN="${ROOT}/scripts/toolchain/${TOOLCHAIN_FILE}"
[ -f "${TOOLCHAIN}" ] || { echo "toolchain not found: ${TOOLCHAIN}" >&2; exit 1; }

if [ -f "${PREFIX}/lib/libcurl.a" ]; then
    echo "curl (${SDK}) already built at ${PREFIX}"
    exit 0
fi

SRC_PARENT="${ROOT}/work/src-deps"
# curl tags are dashed (`curl-8_10_1`), not dotted.
CURL_TAG="curl-$(echo "${CURL_VERSION}" | tr '.' '_')"
SRC_DIR="${SRC_PARENT}/curl-${CURL_VERSION}"
BUILD_DIR="${ROOT}/work/deps-build/curl-${CURL_VERSION}-ios-${SDK}"

mkdir -p "${SRC_PARENT}" "${PREFIX}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${CURL_TAG}" \
        https://github.com/curl/curl.git "${SRC_DIR}"
fi

# Minimum-viable curl for iOS:
#  - HTTPS via SecureTransport (TLS framework that ships with iOS).
#  - Nothing else: no LDAP, no SSH, no PSL, no brotli/zstd, no IDN,
#    no exe binaries. PDAL only needs basic HTTP(S) GET/HEAD.
#  - BUILD_SHARED_LIBS=OFF + CMAKE_POSITION_INDEPENDENT_CODE=ON so
#    libcurl.a slots into ld -r and the final framework Mach-O cleanly.
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCURL_USE_SECTRANSP=ON \
    -DCURL_USE_OPENSSL=OFF \
    -DCURL_USE_MBEDTLS=OFF \
    -DCURL_USE_WOLFSSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBSSH=OFF \
    -DCURL_USE_LIBPSL=OFF \
    -DUSE_LIBIDN2=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_DISABLE_RTSP=ON \
    -DCURL_DISABLE_DICT=ON \
    -DCURL_DISABLE_FILE=ON \
    -DCURL_DISABLE_FTP=ON \
    -DCURL_DISABLE_GOPHER=ON \
    -DCURL_DISABLE_IMAP=ON \
    -DCURL_DISABLE_POP3=ON \
    -DCURL_DISABLE_SMB=ON \
    -DCURL_DISABLE_SMTP=ON \
    -DCURL_DISABLE_TELNET=ON \
    -DCURL_DISABLE_TFTP=ON \
    -DCURL_DISABLE_MQTT=ON

cmake --build "${BUILD_DIR}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${BUILD_DIR}"

LIB="${PREFIX}/lib/libcurl.a"
[ -f "${LIB}" ] || { echo "missing ${LIB} after install" >&2; exit 1; }
ARCHS_OUT="$(lipo -archs "${LIB}" 2>/dev/null || true)"
if [ "${ARCHS_OUT}" != "arm64" ]; then
    echo "unexpected arch in ${LIB}: '${ARCHS_OUT}' (want arm64)" >&2
    exit 1
fi
echo "curl (${SDK}) → ${LIB} (arm64)"
