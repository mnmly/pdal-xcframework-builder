#!/bin/bash
# Build E57Format.xcframework for macOS — bypassing PDAL's E57 plugin.
#
# Why this exists
# ---------------
# PDAL 2.10.x's `readers.e57` bridge throws "E57 exception" partway
# through certain multi-scan E57 files (16+ scans, hundreds of millions
# of points). The same files read cleanly when libE57Format is called
# directly. SwiftPDAL ships a libE57Format → writers.copc bridge as a
# workaround; that bridge needs libE57Format as a build/link target,
# packaged consistently with the rest of the toolchain. This script
# produces `E57Format.xcframework`, mirroring the style of `build.sh`
# (Fetch → Configure → Build → Assemble → Bundle → Sign → xcframework).
#
# Self-containment
# ----------------
# libE57Format depends on Apache Xerces-C. To avoid a runtime dep on
# Homebrew or a sibling framework, we build Xerces-C from source into a
# private sandbox prefix here, then use dylibbundler to pull it into
# E57Format.framework/Versions/A/Libraries/. The resulting xcframework
# has zero external deps beyond the platform C++ runtime.
#
# Usage: ./build_e57.sh <LIBE57FORMAT_VERSION>     e.g. ./build_e57.sh 3.3.0
#        RELEASE=1 ./build_e57.sh <LIBE57FORMAT_VERSION>

set -euo pipefail

LIBE57_VERSION="${1:-}"
if [ -z "${LIBE57_VERSION}" ]; then
    echo "Usage: $0 <libE57Format version>     e.g. $0 3.3.0" >&2
    exit 1
fi

# Xerces-C is the only thing libE57Format pulls in we need to ship. Pin
# it to a known-good release; bump when libE57Format moves to a newer
# required version.
: "${XERCES_VERSION:=3.3.0}"

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${ROOT}/config.sh" ]; then
    echo "Missing ${ROOT}/config.sh — copy config.sh.example and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/config.sh"

: "${OUTPUT_DIR:=${ROOT}/output}"
: "${ARCHS:=arm64}"
: "${DEPLOYMENT_TARGET:=26.0}"
: "${EXTRA_CMAKE_FLAGS:=}"

# Preflight — same toolchain demands as build.sh.
missing=()
for cmd in cmake dylibbundler xcodebuild git plutil otool install_name_tool; do
    command -v "$cmd" >/dev/null || missing+=("$cmd (command)")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install with:  brew install cmake dylibbundler" >&2
    exit 1
fi

WORK="${ROOT}/work/e57-${LIBE57_VERSION}"
XERCES_SRC="${WORK}/xerces-src"
XERCES_BUILD="${WORK}/xerces-build"
XERCES_PREFIX="${WORK}/xerces-prefix"             # sandboxed install
E57_SRC="${WORK}/libE57Format-src"
E57_BUILD="${WORK}/libE57Format-build"
E57_INSTALL="${WORK}/libE57Format-install"
STAGE="${WORK}/stage"
FW="${STAGE}/E57Format.framework"

mkdir -p "${OUTPUT_DIR}"

cmake_arch_flag=""
for a in ${ARCHS}; do cmake_arch_flag="${cmake_arch_flag};${a}"; done
cmake_arch_flag="${cmake_arch_flag#;}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

# ────────────────────────────────────────────────────────────────────
# macOS slice (phases 1–8). iOS slices, when added, get a sibling
# build_ios_slice() that produces a static E57Format.framework with
# libxerces-c.a merged into the single archive. Phase 9 aggregates.
# ────────────────────────────────────────────────────────────────────
build_macos_slice() {

############################################
step "1/9  Fetch + build Xerces-C ${XERCES_VERSION} (sandbox)"
############################################
# We deliberately don't reuse Homebrew's xerces — that would tie the
# framework to /opt/homebrew at runtime. Apache hosts source mirrors but
# the GitHub mirror is fine and matches what the rest of the builder
# uses.
if [ ! -d "${XERCES_SRC}/.git" ]; then
    rm -rf "${XERCES_SRC}"
    git clone --depth 1 --branch "v${XERCES_VERSION}" \
        https://github.com/apache/xerces-c.git "${XERCES_SRC}"
fi

# Configure + build only on a clean slate so version bumps don't reuse
# stale CMakeCache entries.
if [ ! -f "${XERCES_PREFIX}/lib/libxerces-c-3.3.dylib" ] \
   && [ ! -f "${XERCES_PREFIX}/lib/libxerces-c-${XERCES_VERSION%.*}.dylib" ]; then
    rm -rf "${XERCES_BUILD}" "${XERCES_PREFIX}"
    mkdir -p "${XERCES_BUILD}" "${XERCES_PREFIX}"
    cmake -S "${XERCES_SRC}" -B "${XERCES_BUILD}" \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_PREFIX="${XERCES_PREFIX}" \
        -DCMAKE_OSX_ARCHITECTURES="${cmake_arch_flag}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_IGNORE_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_FIND_FRAMEWORK=LAST \
        -Dtranscoder=iconv \
        -Dnetwork=OFF \
        -Dthreads=ON
    cmake --build "${XERCES_BUILD}" -j "$(sysctl -n hw.ncpu)"
    cmake --install "${XERCES_BUILD}"
else
    echo "xerces-c already installed at ${XERCES_PREFIX}"
fi

XERCES_DYLIB="$(find "${XERCES_PREFIX}/lib" -maxdepth 1 -name "libxerces-c-*.dylib" -type f | head -1)"
if [ -z "${XERCES_DYLIB}" ]; then
    echo "Could not locate sandboxed libxerces-c dylib" >&2
    exit 1
fi
echo "xerces dylib: ${XERCES_DYLIB}"

############################################
step "2/9  Fetch libE57Format ${LIBE57_VERSION}"
############################################
if [ ! -d "${E57_SRC}/.git" ]; then
    rm -rf "${E57_SRC}"
    git clone --depth 1 --branch "v${LIBE57_VERSION}" \
        https://github.com/asmaloney/libE57Format.git "${E57_SRC}"
else
    echo "libE57Format source already present at ${E57_SRC}"
fi

############################################
step "3/9  Configure libE57Format against sandboxed Xerces-C"
############################################
rm -rf "${E57_BUILD}" "${E57_INSTALL}" "${STAGE}"
mkdir -p "${E57_BUILD}" "${E57_INSTALL}" "${STAGE}"

cmake -S "${E57_SRC}" -B "${E57_BUILD}" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DCMAKE_INSTALL_PREFIX="${E57_INSTALL}" \
    -DCMAKE_PREFIX_PATH="${XERCES_PREFIX}" \
    -DCMAKE_OSX_ARCHITECTURES="${cmake_arch_flag}" \
    -DCMAKE_IGNORE_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    ${EXTRA_CMAKE_FLAGS}

############################################
step "4/9  Build + install libE57Format"
############################################
cmake --build "${E57_BUILD}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${E57_BUILD}"

E57_DYLIB_REAL="$(find "${E57_INSTALL}/lib" -maxdepth 1 -name "libE57Format.*.*.*.dylib" -type f | head -1)"
if [ -z "${E57_DYLIB_REAL}" ]; then
    E57_DYLIB_REAL="$(find "${E57_INSTALL}/lib" -maxdepth 1 -name "libE57Format.*.dylib" -type f | head -1)"
fi
if [ -z "${E57_DYLIB_REAL}" ]; then
    echo "Could not locate the installed libE57Format dylib in ${E57_INSTALL}/lib" >&2
    exit 1
fi
echo "found dylib: ${E57_DYLIB_REAL}"

############################################
step "5/9  Assemble framework structure"
############################################
mkdir -p \
    "${FW}/Versions/A/Headers" \
    "${FW}/Versions/A/Modules" \
    "${FW}/Versions/A/Libraries" \
    "${FW}/Versions/A/Resources"

# Binary — framework convention: rename libE57Format.X.Y.Z.dylib → E57Format.
cp "${E57_DYLIB_REAL}" "${FW}/Versions/A/E57Format"
chmod +w "${FW}/Versions/A/E57Format"
install_name_tool -id "@rpath/E57Format.framework/Versions/A/E57Format" \
    "${FW}/Versions/A/E57Format"

# Compatibility symlinks so existing soname references resolve to the
# framework binary (libE57Format.3.dylib, libE57Format.dylib).
DYLIB_BASENAME="$(basename "${E57_DYLIB_REAL}")"
SOVERSION="$(echo "${DYLIB_BASENAME}" | sed -E 's/^libE57Format\.([0-9]+)\..*\.dylib$/\1/')"
if ! [[ "${SOVERSION}" =~ ^[0-9]+$ ]]; then
    SOVERSION="$(echo "${DYLIB_BASENAME}" | sed -E 's/^libE57Format\.([0-9]+)\.dylib$/\1/')"
fi
( cd "${FW}/Versions/A" && \
    ln -sf E57Format "libE57Format.${SOVERSION}.dylib" && \
    ln -sf E57Format "libE57Format.dylib" )

# Headers — flatten libE57Format's `include/E57Format/<hdr>.h` into the
# framework's `Headers/<hdr>.h` (Apple framework convention). The
# modulemap below picks `E57Format.h` as its umbrella, which only
# resolves when the headers are flat — and consumers can use either
# `#include <E57Format/E57SimpleReader.h>` or the bare
# `#include <E57SimpleReader.h>` from inside the framework module.
cp -R "${E57_INSTALL}/include/E57Format/." "${FW}/Versions/A/Headers/"

# Modulemap so Swift Cxx interop can `import E57Format` cleanly.
cat > "${FW}/Versions/A/Modules/module.modulemap" <<'EOF'
framework module E57Format {
    umbrella header "E57Format.h"
    requires cplusplus
    export *
    module * { export * }
}
EOF

# Upstream license — libE57Format is BSD-style; binary redistribution
# must carry the notice.
LICENSE_SRC="$(find "${E57_SRC}" -maxdepth 1 -type f -iname 'license*' | head -1)"
if [ -n "${LICENSE_SRC}" ]; then
    cp "${LICENSE_SRC}" "${FW}/Versions/A/Resources/LICENSE.txt"
else
    echo "warning: no LICENSE file found in ${E57_SRC}" >&2
fi

# Xerces ships its own license; carry it alongside.
XERCES_LICENSE="$(find "${XERCES_SRC}" -maxdepth 1 -type f -iname 'license*' | head -1)"
[ -n "${XERCES_LICENSE}" ] && cp "${XERCES_LICENSE}" "${FW}/Versions/A/Resources/LICENSE-xerces.txt" || true

############################################
step "6/9  Bundle xerces-c into the framework + fix rpaths"
############################################
search_flags=( "-s" "${XERCES_PREFIX}/lib" )

cd "${STAGE}"
dylibbundler -od -b -x "./E57Format.framework/Versions/A/E57Format" \
    -d "./E57Format.framework/Versions/A/Libraries/" \
    -p "@loader_path/Libraries/" \
    "${search_flags[@]}"

# Dedupe LC_RPATH entries (cmake + dylibbundler both add them).
dedupe_rpath() {
    local target="$1" path="$2"
    local count
    count=$(otool -l "$target" | grep -c "path ${path} " || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    while [ "$count" -gt 1 ]; do
        install_name_tool -delete_rpath "$path" "$target" 2>/dev/null || break
        count=$(otool -l "$target" | grep -c "path ${path} " || true)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
    done
}
dedupe_rpath "./E57Format.framework/Versions/A/E57Format" "@loader_path/Libraries/"

for lib in ./E57Format.framework/Versions/A/Libraries/*.dylib; do
    [ -e "$lib" ] || continue
    dedupe_rpath "$lib" "@loader_path/Libraries/"
    count=$(otool -l "$lib" | grep -c "cmd LC_RPATH" || true)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if [ "$count" -eq 0 ]; then
        install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
    fi
    otool -L "$lib" | awk '/@loader_path\/Libraries\//{print $1}' | while read -r dep; do
        libname="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$libname" "$lib" 2>/dev/null || true
    done
done

############################################
step "7/9  Top-level framework symlinks + Info.plist"
############################################
PLIST="${FW}/Versions/A/Resources/Info.plist"
cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>English</string>
    <key>CFBundleExecutable</key>             <string>E57Format</string>
    <key>CFBundleIdentifier</key>             <string>com.github.asmaloney.libE57Format</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>E57Format</string>
    <key>CFBundlePackageType</key>            <string>FMWK</string>
    <key>CFBundleShortVersionString</key>     <string>${LIBE57_VERSION}</string>
    <key>CFBundleVersion</key>                <string>${LIBE57_VERSION}</string>
    <key>CFBundleSignature</key>              <string>????</string>
    <key>CSResourcesFileMapped</key>          <true/>
</dict>
</plist>
EOF
plutil -lint "${PLIST}" >/dev/null

( cd "${FW}/Versions" && ln -sfn A Current )
( cd "${FW}" && \
    ln -sfn Versions/Current/E57Format E57Format && \
    ln -sfn Versions/Current/Headers Headers && \
    ln -sfn Versions/Current/Modules Modules && \
    ln -sfn Versions/Current/Libraries Libraries && \
    ln -sfn Versions/Current/Resources Resources )

############################################
step "8/9  Codesign (optional)"
############################################
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "signing inside-out with identity: ${SIGN_ID}"
find "${FW}/Versions/A" -type f \( -name "*.dylib" -o -name "E57Format" \) \
    -exec codesign --force --sign "${SIGN_ID}" --timestamp=none {} \;
codesign --force --sign "${SIGN_ID}" --timestamp=none --deep "${FW}"

}  # end build_macos_slice

# ────────────────────────────────────────────────────────────────────
# iOS slice. Static framework: libE57Format.a + libxerces-c.a merged
# into a single Mach-O archive via libtool. Flat layout (no Versions/),
# no codesign (Xcode signs the app bundle that embeds this).
# ────────────────────────────────────────────────────────────────────
build_ios_slice() {
    local sdk="$1"  # device | simulator

    local slice_name toolchain_name platform_name
    case "${sdk}" in
        device)
            slice_name="ios-arm64"
            toolchain_name="ios-device.cmake"
            platform_name="iPhoneOS"
            ;;
        simulator)
            slice_name="ios-arm64-simulator"
            toolchain_name="ios-sim.cmake"
            platform_name="iPhoneSimulator"
            ;;
        *) echo "build_ios_slice: unknown sdk '${sdk}'" >&2; return 2 ;;
    esac

    local toolchain="${ROOT}/scripts/toolchain/${toolchain_name}"
    local xerces_prefix="${ROOT}/work/deps-cache/ios-${sdk}/xerces-c-${XERCES_VERSION}"
    local e57_build="${WORK}/build-${slice_name}"
    local e57_install="${WORK}/install-${slice_name}"
    local stage_ios="${WORK}/stage-${slice_name}"
    local fw_ios="${stage_ios}/E57Format.framework"

    step "iOS/${sdk}: 1) build xerces-c"
    XERCES_VERSION="${XERCES_VERSION}" \
        "${ROOT}/scripts/deps/xerces-c.sh" "${sdk}" "${xerces_prefix}"

    step "iOS/${sdk}: 2) configure libE57Format (static)"
    rm -rf "${e57_build}" "${e57_install}" "${stage_ios}"
    mkdir -p "${e57_build}" "${e57_install}" "${stage_ios}"
    # find_package(XercesC) can't discover the cross-compiled prefix via
    # CMAKE_PREFIX_PATH because the toolchain pins
    # CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY (intentional — keeps host
    # libs out of cross builds). Bypass with explicit XercesC_* vars.
    cmake -S "${E57_SRC}" -B "${e57_build}" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
        -DCMAKE_INSTALL_PREFIX="${e57_install}" \
        -DXercesC_LIBRARY="${xerces_prefix}/lib/libxerces-c.a" \
        -DXercesC_INCLUDE_DIR="${xerces_prefix}/include" \
        -DXercesC_VERSION="${XERCES_VERSION}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        ${EXTRA_CMAKE_FLAGS}

    step "iOS/${sdk}: 3) build + install libE57Format"
    cmake --build "${e57_build}" -j "$(sysctl -n hw.ncpu)"
    cmake --install "${e57_build}"

    local e57_archive="${e57_install}/lib/libE57Format.a"
    [ -f "${e57_archive}" ] || {
        echo "missing ${e57_archive} after install" >&2
        return 1
    }

    step "iOS/${sdk}: 4) assemble flat framework (relocatable Mach-O)"
    mkdir -p "${fw_ios}/Headers" "${fw_ios}/Modules"

    # xcodebuild -create-xcframework rejects framework binaries that are
    # ar archives ("Unknown header: 0xb17c0de"). It expects a single
    # Mach-O object. Use ld -r to relocatably link all members of both
    # static archives into one MH_OBJECT. This also merges xerces-c
    # symbols into the E57Format binary, identical to the macOS slice's
    # dylibbundler approach in spirit.
    local objdir="${stage_ios}/objs"
    rm -rf "${objdir}" && mkdir -p "${objdir}"
    ( cd "${objdir}" && \
        ar -x "${e57_archive}" && \
        ar -x "${xerces_prefix}/lib/libxerces-c.a" )

    local sdk_root sdk_platform
    case "${sdk}" in
        device)    sdk_root="$(xcrun --sdk iphoneos --show-sdk-path)" ;;
        simulator) sdk_root="$(xcrun --sdk iphonesimulator --show-sdk-path)" ;;
    esac
    case "${sdk}" in
        device)    sdk_platform="ios" ;;
        simulator) sdk_platform="ios-simulator" ;;
    esac

    ld -r -arch arm64 \
        -syslibroot "${sdk_root}" \
        -platform_version "${sdk_platform}" "${IOS_DEPLOYMENT_TARGET:-17.0}" "${IOS_DEPLOYMENT_TARGET:-17.0}" \
        -o "${fw_ios}/E57Format" \
        "${objdir}"/*.o
    rm -rf "${objdir}"

    # Headers — flatten libE57Format's include/E57Format/ into Headers/
    # to match the macOS slice and keep the umbrella header path
    # (E57Format.h) directly resolvable from the modulemap.
    cp -R "${e57_install}/include/E57Format/." "${fw_ios}/Headers/"

    cat > "${fw_ios}/Modules/module.modulemap" <<'EOF'
framework module E57Format {
    umbrella header "E57Format.h"
    requires cplusplus
    export *
    module * { export * }
}
EOF

    cat > "${fw_ios}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>English</string>
    <key>CFBundleExecutable</key>             <string>E57Format</string>
    <key>CFBundleIdentifier</key>             <string>com.github.asmaloney.libE57Format</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>E57Format</string>
    <key>CFBundlePackageType</key>            <string>FMWK</string>
    <key>CFBundleShortVersionString</key>     <string>${LIBE57_VERSION}</string>
    <key>CFBundleVersion</key>                <string>${LIBE57_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key>     <array><string>${platform_name}</string></array>
    <key>MinimumOSVersion</key>               <string>${IOS_DEPLOYMENT_TARGET:-17.0}</string>
</dict>
</plist>
EOF
    plutil -lint "${fw_ios}/Info.plist" >/dev/null

    # Licenses, flat layout — sit at framework root for static iOS frameworks.
    local lic_e57 lic_xerces
    lic_e57="$(find "${E57_SRC}" -maxdepth 1 -type f -iname 'license*' | head -1)"
    [ -n "${lic_e57}" ] && cp "${lic_e57}" "${fw_ios}/LICENSE.txt" || true
    lic_xerces="$(find "${XERCES_SRC}" -maxdepth 1 -type f -iname 'license*' | head -1)"
    [ -n "${lic_xerces}" ] && cp "${lic_xerces}" "${fw_ios}/LICENSE-xerces.txt" || true

    IOS_FRAMEWORKS+=("${fw_ios}")
    echo "iOS/${sdk} framework: ${fw_ios}"
}

build_macos_slice

IOS_FRAMEWORKS=()
if [ "${BUILD_IOS:-0}" = "1" ]; then
    build_ios_slice device
    build_ios_slice simulator
fi

############################################
step "9/9  Wrap in xcframework + zip"
############################################
XC_OUT="${OUTPUT_DIR}/E57Format.xcframework"
rm -rf "${XC_OUT}"
xcframework_args=( -framework "${FW}" )
for fw in "${IOS_FRAMEWORKS[@]:-}"; do
    [ -n "${fw}" ] && xcframework_args+=( -framework "${fw}" )
done
xcodebuild -create-xcframework "${xcframework_args[@]}" -output "${XC_OUT}"

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/E57Format.xcframework"
    cp -R "${XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/E57Format.xcframework"
fi

cd "${OUTPUT_DIR}"
ZIP="E57Format.xcframework.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent E57Format.xcframework "${ZIP}"

CHECKSUM=""
if command -v swift >/dev/null 2>&1; then
    CHECKSUM="$(swift package compute-checksum "${ZIP}")"
fi

printf "\n\033[1;32mDONE\033[0m  %s\n" "${XC_OUT}"
printf "      zip: %s\n" "${OUTPUT_DIR}/${ZIP}"
[ -n "${CHECKSUM}" ] && printf "      swift checksum: %s\n" "${CHECKSUM}"

if [ "${RELEASE:-0}" = "1" ]; then
    if [ -z "${GH_RELEASE_REPO:-}" ]; then
        echo "RELEASE=1 set but GH_RELEASE_REPO is empty in config.sh — skipping gh release" >&2
        exit 0
    fi
    TAG="libE57Format-v${LIBE57_VERSION}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    gh release create "${TAG}" "${OUTPUT_DIR}/${ZIP}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "libE57Format v${LIBE57_VERSION} Framework" \
        --notes "Self-contained binary framework for libE57Format v${LIBE57_VERSION} (xerces-c ${XERCES_VERSION} bundled)"
fi
