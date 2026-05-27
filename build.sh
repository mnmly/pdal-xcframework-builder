#!/bin/bash
# Build pdalcpp.xcframework for macOS from a tagged upstream PDAL release.
#
# PDAL's CMake doesn't natively emit a .framework on install — it produces a
# regular dylib + headers. This script does a normal install, then assembles
# a proper macOS framework structure from the install output.
#
# Usage: ./build.sh <PDAL_VERSION>           e.g. ./build.sh 2.10.1
#        RELEASE=1 ./build.sh <PDAL_VERSION>
set -euo pipefail

PDAL_VERSION="${1:-}"
if [ -z "${PDAL_VERSION}" ]; then
    echo "Usage: $0 <PDAL_VERSION>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${ROOT}/config.sh" ]; then
    echo "Missing ${ROOT}/config.sh — copy config.sh.example and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/config.sh"

: "${GDAL_XCFRAMEWORK:?GDAL_XCFRAMEWORK must be set in config.sh}"
: "${PROJ_PREFIX:?PROJ_PREFIX must be set in config.sh}"
: "${OUTPUT_DIR:=${ROOT}/output}"
: "${ARCHS:=arm64}"
: "${DEPLOYMENT_TARGET:=26.0}"
: "${ENABLED_PLUGINS:=E57}"
: "${EXTRA_CMAKE_FLAGS:=}"
: "${DYLIBBUNDLER_SEARCH_PATHS:=/opt/homebrew/lib /opt/homebrew/opt/expat/lib /opt/homebrew/opt/xerces-c/lib}"

# Preflight
missing=()
for cmd in cmake dylibbundler xcodebuild git plutil otool install_name_tool; do
    command -v "$cmd" >/dev/null || missing+=("$cmd (command)")
done
[ -f /opt/homebrew/opt/expat/lib/libexpat.1.dylib ] || missing+=("expat (brew install expat)")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install with:  brew install cmake dylibbundler expat" >&2
    exit 1
fi

GDAL_DIR="${GDAL_XCFRAMEWORK}/macos-arm64/gdal.framework/Versions/Current/lib/cmake/gdal"
if [ ! -d "${GDAL_DIR}" ]; then
    echo "Could not find GDAL cmake config at ${GDAL_DIR}" >&2
    echo "Check GDAL_XCFRAMEWORK in config.sh." >&2
    exit 1
fi

PROJ_DIR="${PROJ_PREFIX}/lib/cmake/proj"
PROJ_DB_SRC="${PROJ_PREFIX}/share/proj/proj.db"
[ -f "${PROJ_DB_SRC}" ] || { echo "proj.db not found at ${PROJ_DB_SRC}" >&2; exit 1; }

WORK="${ROOT}/work/pdal-${PDAL_VERSION}"
SRC_DIR="${WORK}/src"
BUILD_DIR="${WORK}/build"
INSTALL_DIR="${WORK}/install"
STAGE="${WORK}/stage"               # where we assemble the .framework
FW="${STAGE}/pdalcpp.framework"

mkdir -p "${OUTPUT_DIR}"

cmake_arch_flag=""
for a in ${ARCHS}; do cmake_arch_flag="${cmake_arch_flag};${a}"; done
cmake_arch_flag="${cmake_arch_flag#;}"

plugin_flags=()
for p in ${ENABLED_PLUGINS}; do plugin_flags+=("-DBUILD_PLUGIN_${p}=ON"); done

export CPLUS_INCLUDE_PATH="/opt/homebrew/include:${CPLUS_INCLUDE_PATH:-}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

############################################
step "1/8  Fetch PDAL ${PDAL_VERSION}"
############################################
if [ -z "${PDAL_TAG:-}" ]; then
    if git ls-remote --tags https://github.com/PDAL/PDAL.git "refs/tags/${PDAL_VERSION}" \
        | grep -q "${PDAL_VERSION}"; then
        PDAL_TAG="${PDAL_VERSION}"
    else
        PDAL_TAG="v${PDAL_VERSION}"
    fi
fi
echo "using tag: ${PDAL_TAG}"

if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "${PDAL_TAG}" \
        https://github.com/PDAL/PDAL.git "${SRC_DIR}"
else
    echo "source already present at ${SRC_DIR}"
fi

############################################
step "1.5  Patch vendored lazperf"
############################################
# PDAL vendors an older laz-perf snapshot at src/vendor/lazperf/. SwiftPDAL's
# copclib.xcframework bundles upstream laz-perf master plus a local patch that
# adds `virtual void las_decompressor::reset(InputCb)` (a new vtable slot). If
# the two archives are linked into one consumer binary (iOS), their vtables
# disagree and virtual dispatch from copclib lands on the wrong slot
# (__cxa_pure_virtual at runtime). Apply the same patch here so both
# archives expose an identical lazperf ABI.
#
# Applied to source (not at configure time) because lazperf is built by
# PDAL's own CMake and we need the patched headers visible to every TU.
# Idempotent: reverse-check first, skip if already applied. Mirrors the
# pattern in SwiftPDAL/scripts/build-copc-xcframework.sh.
: "${LAZPERF_PATCHES_DIR:=${ROOT}/resources/lazperf-patches}"
if [ -d "${LAZPERF_PATCHES_DIR}" ]; then
    shopt -s nullglob
    lazperf_patches=( "${LAZPERF_PATCHES_DIR}"/*.patch )
    shopt -u nullglob
    for p in "${lazperf_patches[@]}"; do
        pushd "${SRC_DIR}" >/dev/null
        # Patch uses `a/cpp/lazperf/<file>` paths (it was authored against
        # upstream hobuinc/laz-perf where headers live under cpp/lazperf/).
        # PDAL's vendored copy is at vendor/lazperf/<file>. -p3 strips
        # `a/cpp/lazperf/` down to the bare filename; --directory then
        # prepends `vendor/lazperf/`. pushd into SRC_DIR first so the
        # path is relative to PDAL's tree root.
        if git apply --reverse --check -p3 --directory=vendor/lazperf "${p}" 2>/dev/null; then
            echo "==> lazperf patch already applied: $(basename "${p}")"
        elif git apply --check -p3 --directory=vendor/lazperf "${p}" 2>/dev/null; then
            echo "==> Applying lazperf patch: $(basename "${p}")"
            git apply -p3 --directory=vendor/lazperf "${p}"
        else
            echo "ERROR: lazperf patch $(basename "${p}") does not cleanly apply or reverse-apply" >&2
            popd >/dev/null
            exit 1
        fi
        popd >/dev/null
    done
else
    echo "no lazperf patches dir at ${LAZPERF_PATCHES_DIR} — skipping"
fi

# ────────────────────────────────────────────────────────────────────
# macOS slice (phases 2–7). iOS slices, when added, get a sibling
# build_ios_slice() function called below. Each slice writes its
# framework into ${STAGE} and Phase 8 aggregates.
# ────────────────────────────────────────────────────────────────────
build_macos_slice() {

############################################
step "2/8  Configure"
############################################
rm -rf "${BUILD_DIR}" "${INSTALL_DIR}" "${STAGE}"
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}" "${STAGE}"

# Standard install layout — no framework cmake. We assemble the .framework
# ourselves in phase 4 from the install output.
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    "${plugin_flags[@]}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
    -DBUILD_SHARED_LIBS=ON \
    -DPROJ_DIR="${PROJ_DIR}" \
    -DGDAL_DIR="${GDAL_DIR}" \
    -DCMAKE_OSX_ARCHITECTURES="${cmake_arch_flag}" \
    -DCMAKE_IGNORE_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    ${EXTRA_CMAKE_FLAGS}

############################################
step "3/8  Build + install"
############################################
cmake --build "${BUILD_DIR}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${BUILD_DIR}"

# Sanity check
PDAL_DYLIB_REAL="$(find "${INSTALL_DIR}/lib" -maxdepth 1 -name "libpdalcpp.*.*.*.dylib" -type f | head -1)"
if [ -z "${PDAL_DYLIB_REAL}" ]; then
    echo "Could not locate the installed libpdalcpp dylib in ${INSTALL_DIR}/lib" >&2
    exit 1
fi
echo "found dylib: ${PDAL_DYLIB_REAL}"

############################################
step "4/8  Assemble framework structure"
############################################
mkdir -p \
    "${FW}/Versions/A/Headers" \
    "${FW}/Versions/A/Modules" \
    "${FW}/Versions/A/Libraries" \
    "${FW}/Versions/A/PlugIns" \
    "${FW}/Versions/A/Resources"

# Binary
cp "${PDAL_DYLIB_REAL}" "${FW}/Versions/A/pdalcpp"
chmod +w "${FW}/Versions/A/pdalcpp"
install_name_tool -id "@rpath/pdalcpp.framework/Versions/A/pdalcpp" \
    "${FW}/Versions/A/pdalcpp"

# Compatibility symlink so plugins linked to libpdalcpp.<soversion>.dylib
# still resolve to the framework binary.
DYLIB_BASENAME="$(basename "${PDAL_DYLIB_REAL}")"          # libpdalcpp.20.1.0.dylib
SOVERSION="$(echo "${DYLIB_BASENAME}" | sed -E 's/^libpdalcpp\.([0-9]+)\..*\.dylib$/\1/')"
( cd "${FW}/Versions/A" && \
    ln -sf pdalcpp "libpdalcpp.${SOVERSION}.dylib" && \
    ln -sf pdalcpp "libpdalcpp.dylib" )

# Headers (matches existing layout: Headers/pdal/...)
cp -R "${INSTALL_DIR}/include/pdal" "${FW}/Versions/A/Headers/pdal"

# Modulemap (shipped with the builder)
cp "${ROOT}/resources/module.modulemap" "${FW}/Versions/A/Modules/module.modulemap"

# Plugins (if any landed in lib/)
shopt -s nullglob
plugin_files=( "${INSTALL_DIR}/lib/"libpdal_plugin_*.dylib )
shopt -u nullglob
if [ "${#plugin_files[@]}" -gt 0 ]; then
    cp -P "${plugin_files[@]}" "${FW}/Versions/A/PlugIns/"
    # Repoint plugins from @rpath/libpdalcpp.X.dylib at the framework binary.
    for plug in "${FW}/Versions/A/PlugIns/"*.dylib; do
        [ -L "$plug" ] && continue
        otool -L "$plug" | awk '/libpdalcpp/ {print $1}' | while read -r ref; do
            install_name_tool -change "$ref" \
                "@rpath/pdalcpp.framework/Versions/A/pdalcpp" "$plug" 2>/dev/null || true
        done
        # Plugins are dlopen'd from PlugIns/ — give them an rpath up to the
        # framework root so @rpath/pdalcpp.framework/... resolves.
        install_name_tool -add_rpath "@loader_path/../../.." "$plug" 2>/dev/null || true
        # The E57 plugin links against libE57Format via @rpath/libE57Format.X.dylib.
        # libE57Format.X.dylib lives as a symlink inside
        # E57Format.framework/Versions/A/, not at the Frameworks/ root,
        # so the `@loader_path/../../..` rpath alone doesn't resolve it.
        # Add a second rpath that points into E57Format.framework's
        # Versions/A. Plugins that don't reference libE57Format ignore
        # the extra path harmlessly.
        #
        # 4 `../` levels: plugin sits at
        # pdalcpp.framework/Versions/A/PlugIns/<dylib>, so going up
        # PlugIns → Versions/A → Versions → pdalcpp.framework →
        # Frameworks (4 hops). E57Format.framework is a sibling at
        # Frameworks/.
        install_name_tool -add_rpath \
            "@loader_path/../../../../E57Format.framework/Versions/A" \
            "$plug" 2>/dev/null || true
    done
    echo "copied ${#plugin_files[@]} plugin(s)"
fi

# proj.db
cp "${PROJ_DB_SRC}" "${FW}/Versions/A/Resources/proj.db"

# Info.plist (built fresh — the user's old recipe used smart-quote curly chars
# that got literally embedded in CFBundleVersion strings).
PLIST="${FW}/Versions/A/Resources/Info.plist"
cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>English</string>
    <key>CFBundleExecutable</key>             <string>pdalcpp</string>
    <key>CFBundleIdentifier</key>             <string>org.osgeo.pdalcpp</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>pdalcpp</string>
    <key>CFBundlePackageType</key>            <string>FMWK</string>
    <key>CFBundleShortVersionString</key>     <string>${PDAL_VERSION}</string>
    <key>CFBundleVersion</key>                <string>${PDAL_VERSION}</string>
    <key>CFBundleSignature</key>              <string>????</string>
    <key>CSResourcesFileMapped</key>          <true/>
</dict>
</plist>
EOF
plutil -lint "${PLIST}" >/dev/null

# Upstream license — PDAL is BSD-style; binary redistribution must carry
# the notice. Ship it inside the framework's Resources/.
LICENSE_SRC="$(find "${SRC_DIR}" -maxdepth 1 -type f -iname 'license*' | head -1)"
if [ -n "${LICENSE_SRC}" ]; then
    cp "${LICENSE_SRC}" "${FW}/Versions/A/Resources/LICENSE.txt"
else
    echo "warning: no LICENSE file found in ${SRC_DIR}" >&2
fi

############################################
step "5/8  Bundle dylib deps + fix rpaths"
############################################
search_flags=()
for p in ${DYLIBBUNDLER_SEARCH_PATHS}; do
    [ -d "$p" ] && search_flags+=("-s" "$p")
done

cd "${STAGE}"
dylibbundler -od -b -x "./pdalcpp.framework/Versions/A/pdalcpp" \
    -d "./pdalcpp.framework/Versions/A/Libraries/" \
    -p "@loader_path/Libraries/" \
    "${search_flags[@]}"

# Dedupe duplicate `@loader_path/Libraries/` rpaths anywhere they appear.
# ld errors on duplicate LC_RPATH when the framework is consumed downstream.
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

# Main binary: dedupe LC_RPATHs added by both cmake and dylibbundler.
dedupe_rpath "./pdalcpp.framework/Versions/A/pdalcpp" "@loader_path/Libraries/"

# Normalise rpaths inside bundled dylibs so siblings resolve via @loader_path.
for lib in ./pdalcpp.framework/Versions/A/Libraries/*.dylib; do
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
step "6/8  Top-level framework symlinks"
############################################
( cd "${FW}/Versions" && ln -sfn A Current )
( cd "${FW}" && \
    ln -sfn Versions/Current/pdalcpp pdalcpp && \
    ln -sfn Versions/Current/Headers Headers && \
    ln -sfn Versions/Current/Modules Modules && \
    ln -sfn Versions/Current/Libraries Libraries && \
    ln -sfn Versions/Current/Resources Resources && \
    ln -sfn Versions/Current/PlugIns PlugIns )

############################################
step "7/8  Codesign (optional)"
############################################
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "signing inside-out with identity: ${SIGN_ID}"
# Sign every nested Mach-O first (dylibs, plug-ins, framework binary),
# then seal the bundle. macOS 26 rejects pages whose nested-library
# signatures don't match the outer bundle's resource hashes.
find "${FW}/Versions/A" -type f \( -name "*.dylib" -o -name "pdalcpp" \) \
    -exec codesign --force --sign "${SIGN_ID}" --timestamp=none {} \;
codesign --force --sign "${SIGN_ID}" --timestamp=none --deep "${FW}"

}  # end build_macos_slice

# ────────────────────────────────────────────────────────────────────
# iOS slice. PDAL static (BUILD_SHARED_LIBS=OFF) against the iOS
# slices of gdal.xcframework + proj.xcframework. The E57 reader is
# NOT built by PDAL's CMake (BUILD_PLUGIN_E57=OFF); instead we
# compile the 5 plugin .cpp files out-of-tree with a force-included
# shim header that redirects CREATE_SHARED_STAGE → CREATE_STATIC_STAGE,
# then relocatably link them into libpdalcpp.a's members via ld -r
# to produce a single MH_OBJECT framework binary.
# ────────────────────────────────────────────────────────────────────
build_ios_slice() {
    local sdk="$1"  # device | simulator

    local slice_name toolchain_name platform_name sdk_id triple_suffix
    case "${sdk}" in
        device)
            slice_name="ios-arm64"
            toolchain_name="ios-device.cmake"
            platform_name="iPhoneOS"
            sdk_id="iphoneos"
            triple_suffix=""
            ;;
        simulator)
            slice_name="ios-arm64-simulator"
            toolchain_name="ios-sim.cmake"
            platform_name="iPhoneSimulator"
            sdk_id="iphonesimulator"
            triple_suffix="-simulator"
            ;;
        *) echo "build_ios_slice: unknown sdk '${sdk}'" >&2; return 2 ;;
    esac

    local toolchain="${ROOT}/scripts/toolchain/${toolchain_name}"
    local sdk_root
    sdk_root="$(xcrun --sdk "${sdk_id}" --show-sdk-path)"

    # libcurl: PDAL's arbiter eagerly constructs an HTTP Pool on
    # startup. iOS SDK ships no libcurl, so we cross-build a minimal
    # static curl (HTTPS via SecureTransport, no extras). Bundled into
    # the framework binary at the ld -r merge step below.
    local curl_version="${CURL_VERSION:-8.10.1}"
    local curl_prefix="${ROOT}/work/deps-cache/ios-${sdk}/curl-${curl_version}"
    CURL_VERSION="${curl_version}" \
        "${ROOT}/scripts/deps/curl.sh" "${sdk}" "${curl_prefix}"

    local gdal_dir="${GDAL_XCFRAMEWORK}/${slice_name}/gdal.framework/lib/cmake/gdal"
    local proj_dir="${PROJ_XCFRAMEWORK}/${slice_name}/proj.framework/lib/cmake/proj"
    # E57Format-ios.xcframework is a library xcframework — headers live
    # directly under <slice>/Headers.
    local e57_headers="${E57FORMAT_XCFRAMEWORK_RESOLVED}/${slice_name}/Headers"
    local proj_fw="${PROJ_XCFRAMEWORK}/${slice_name}/proj.framework"
    [ -d "${gdal_dir}" ] || { echo "missing GDAL cmake config: ${gdal_dir}" >&2; return 1; }
    [ -d "${proj_dir}" ] || { echo "missing PROJ cmake config: ${proj_dir}" >&2; return 1; }
    [ -d "${e57_headers}" ] || { echo "missing E57Format headers: ${e57_headers}" >&2; return 1; }
    [ -f "${proj_fw}/proj" ] || { echo "missing PROJ binary: ${proj_fw}/proj" >&2; return 1; }

    local build_dir_ios="${WORK}/build-${slice_name}"
    local install_dir_ios="${WORK}/install-${slice_name}"
    local stage_ios="${WORK}/stage-${slice_name}"

    step "iOS/${sdk}: 1) Configure PDAL static"
    rm -rf "${build_dir_ios}" "${install_dir_ios}" "${stage_ios}"
    mkdir -p "${build_dir_ios}" "${install_dir_ios}" "${stage_ios}"

    # Upstream patches needed only for iOS static builds. All wrapped in
    # the same `.ios-static.bak` restoration scheme so macOS reruns are
    # unaffected.
    #
    # 1) libraries.cmake: PDAL_LIB_TYPE is set without CACHE so
    #    BUILD_SHARED_LIBS=OFF can't override it. Patch to STATIC.
    # 2) arbiter.cmake: PDAL's arbiter unconditionally pulls in CURL.
    #    iOS doesn't need network/HTTP arbiter ops; drop the CURL
    #    integration. arbiter.cpp's curl-using code paths are already
    #    ifdef-guarded by ARBITER_CURL.
    # 3) CMakeLists.txt: install(EXPORT PDALTargets) fails when
    #    PDAL_LIB_TYPE=STATIC because vendor static libs (pdal_h3,
    #    pdal_arbiter, etc.) aren't in the export set. We don't ship
    #    PDAL's cmake config downstream (consumers use the framework's
    #    module map), so drop the export entirely.
    local libs_cmake="${SRC_DIR}/cmake/libraries.cmake"
    local top_cmake="${SRC_DIR}/CMakeLists.txt"
    sed -i.ios-static.bak \
        's|^set(PDAL_LIB_TYPE "SHARED")|set(PDAL_LIB_TYPE "STATIC")|' \
        "${libs_cmake}"
    cp "${top_cmake}" "${top_cmake}.ios-static.bak"
    python3 - "${top_cmake}" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'export\(\s*TARGETS[^)]*PDALTargets\.cmake"\)', '# ios: export(TARGETS) disabled', s)
s = re.sub(r'install\(\s*EXPORT\s+PDALTargets[^)]*cmake/PDAL"\)', '# ios: install(EXPORT PDALTargets) disabled', s)
open(p, 'w').write(s)
PY
    # shellcheck disable=SC2064
    trap "
        mv '${libs_cmake}.ios-static.bak' '${libs_cmake}' 2>/dev/null
        mv '${top_cmake}.ios-static.bak' '${top_cmake}' 2>/dev/null
        true
    " RETURN

    # NB: BUILD_PLUGIN_E57=OFF — we compile the plugin out-of-tree to
    # keep PDAL's hardcoded `add_library(... SHARED ...)` in macros.cmake
    # from emitting a useless iOS dylib. See tasks/lessons.md.
    # dimbuilder is a code-gen executable PDAL builds + runs during its
    # own build. Cross-compiled iOS binary can't execute on host —
    # PDAL's dimension.cmake exposes DIMBUILDER_EXECUTABLE for this
    # exact case. Point it at the macOS-host build's binary.
    local host_dimbuilder="${BUILD_DIR}/bin/dimbuilder"
    if [ ! -x "${host_dimbuilder}" ]; then
        echo "host dimbuilder not found at ${host_dimbuilder}" >&2
        echo "Run a macOS build first (without SKIP_MACOS=1)." >&2
        return 1
    fi

    cmake -S "${SRC_DIR}" -B "${build_dir_ios}" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
        -DDIMBUILDER_EXECUTABLE="${host_dimbuilder}" \
        -DCMAKE_INSTALL_PREFIX="${install_dir_ios}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_PLUGIN_E57=OFF \
        -DBUILD_TOOLS_LASDUMP=OFF \
        -DBUILD_TOOLS_NITFWRAP=OFF \
        -DWITH_TESTS=OFF \
        -DGDAL_DIR="${gdal_dir}" \
        -DPROJ_DIR="${proj_dir}" \
        -DPROJ_LIBRARY="${proj_fw}/proj" \
        -DPROJ_INCLUDE_DIR="${proj_fw}/Headers" \
        -DTIFF_LIBRARY="${gdal_dir}/.." \
        -DTIFF_INCLUDE_DIR="${gdal_dir}/.." \
        -DCURL_LIBRARY="${curl_prefix}/lib/libcurl.a" \
        -DCURL_INCLUDE_DIR="${curl_prefix}/include" \
        -DGEOTIFF_LIBRARY="${gdal_dir}/.." \
        -DGEOTIFF_INCLUDE_DIR="${ROOT}/scripts/stubs/include" \
        -DZLIB_LIBRARY="${sdk_root}/usr/lib/libz.tbd" \
        -DZLIB_INCLUDE_DIR="${sdk_root}/usr/include" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_MACOSX_BUNDLE=OFF \
        ${EXTRA_CMAKE_FLAGS}

    step "iOS/${sdk}: 2) Build pdalcpp (static lib only)"
    # We only need libpdalcpp.a + headers. The `pdal` CLI and faux plugin
    # targets fail to link because they expect a usable CURL::libcurl as
    # a real lib dependency; in our static config their IMPORTED_LOCATION
    # ends up as CURL::libcurl-NOTFOUND (a literal Make token that
    # breaks parsing). Restricting the build target to pdalcpp avoids
    # all that — we manually stage the artifacts below.
    cmake --build "${build_dir_ios}" --target pdalcpp -j "$(sysctl -n hw.ncpu)"

    local libpdal="${build_dir_ios}/libpdalcpp.a"
    [ -f "${libpdal}" ] || { echo "missing ${libpdal}" >&2; return 1; }

    # Stage headers into a synthetic install tree mirroring what
    # `cmake --install` would have produced for the pdalcpp target.
    mkdir -p "${install_dir_ios}/include" "${install_dir_ios}/lib"
    cp "${libpdal}" "${install_dir_ios}/lib/libpdalcpp.a"
    # Source-tree headers
    cp -R "${SRC_DIR}/pdal" "${install_dir_ios}/include/pdal"
    # Generated headers from the build tree (Dimension.hpp,
    # pdal_features.hpp, pdal_config.hpp, etc.)
    if [ -d "${build_dir_ios}/include/pdal" ]; then
        cp -R "${build_dir_ios}/include/pdal/." "${install_dir_ios}/include/pdal/"
    fi
    libpdal="${install_dir_ios}/lib/libpdalcpp.a"

    step "iOS/${sdk}: 3) Out-of-tree compile E57 plugin (static via shim)"
    local plugin_objdir="${stage_ios}/plugin-objs"
    mkdir -p "${plugin_objdir}"
    local triple="arm64-apple-ios${IOS_DEPLOYMENT_TARGET:-17.0}${triple_suffix}"
    local plugin_src="${SRC_DIR}/plugins/e57/io"
    local plugin_includes=(
        -I"${install_dir_ios}/include"
        # E57Format headers ship under Headers/E57Format/ (matches the
        # `<E57Format/...>`-style includes consumers like SwiftPDAL's
        # CxxPDAL use). PDAL's plugin sources include `<E57Format.h>`
        # bare, so also expose the inner dir as an -I to satisfy that.
        -I"${e57_headers}"
        -I"${e57_headers}/E57Format"
        -I"${SRC_DIR}/vendor"
        -I"${SRC_DIR}/vendor/nlohmann"
        -I"${plugin_src}"
    )
    local plugin_files=( E57Reader.cpp E57Writer.cpp Scan.cpp Utils.cpp Uuid.cpp )
    for src in "${plugin_files[@]}"; do
        xcrun -sdk "${sdk_id}" clang++ \
            -target "${triple}" \
            -isysroot "${sdk_root}" \
            -arch arm64 \
            -std=c++17 \
            -fPIC \
            -O2 \
            -fno-objc-arc \
            -DPDAL_DLL_EXPORT \
            -DARBITER_ZLIB -DARBITER_DLL_IMPORT \
            -include "${ROOT}/scripts/plugin_static_shim.hpp" \
            "${plugin_includes[@]}" \
            -c "${plugin_src}/${src}" \
            -o "${plugin_objdir}/${src%.cpp}.o"
    done

    # Static-plugin anchor TU. Exposes `extern "C" void
    # pdal_ensure_static_plugins()` which downstream consumers call
    # once to drag plugin-tree stages (E57Reader, etc.) out of the
    # merged archive on iOS — where ld64 would otherwise strip them
    # for being referenced only by a TU-internal `static bool _b`.
    # See scripts/pdal_static_anchors.cpp for the rationale.
    xcrun -sdk "${sdk_id}" clang++ \
        -target "${triple}" \
        -isysroot "${sdk_root}" \
        -arch arm64 \
        -std=c++17 \
        -fPIC \
        -O2 \
        -fno-objc-arc \
        -DPDAL_DLL_EXPORT \
        -DARBITER_ZLIB -DARBITER_DLL_IMPORT \
        -include "${ROOT}/scripts/plugin_static_shim.hpp" \
        "${plugin_includes[@]}" \
        -c "${ROOT}/scripts/pdal_static_anchors.cpp" \
        -o "${plugin_objdir}/pdal_static_anchors.o"

    step "iOS/${sdk}: 4) Assemble library xcframework slice"
    # Library xcframework slice (not framework). Xcode's framework-embed
    # pipeline corrupts static iOS framework binaries: an MH_OBJECT
    # framework binary gets silently stripped down to a ~50KB stub at
    # embed time, producing `MIInstallerErrorDomain Code 35
    # PackageInspectionFailed` from `installd`. Static iOS xcframeworks
    # ship as `<slice>/lib<name>.a + Headers/` (no .framework wrapper)
    # — `copclib.xcframework` already follows this pattern. Xcode then
    # links the static archive's symbols directly into the consumer
    # app's main binary; no embedded framework to validate.
    mkdir -p "${stage_ios}/Headers"

    # ld -r directly on each archive — extracts members internally by
    # archive index, no filename collisions. (ar -x DROPS members on
    # name collision: PDAL has duplicate basenames like Expression.cpp.o
    # under filters/private/expr/ and filters/private/mongoexpression/,
    # which would silently mask one definition and break consumer link
    # with "symbol not found in flat namespace 'pdal::expr::Expression::print'".)
    #
    # Use -force_load on each .a so ld pulls in ALL members, including
    # static-init globals that would otherwise be dropped (E57Reader
    # registrar, etc.).
    local vendor_libs=(
        "${build_dir_ios}/vendor/lazperf/libpdal_lazperf.a"
        "${build_dir_ios}/vendor/kazhdan/libpdal_kazhdan.a"
        "${build_dir_ios}/vendor/h3/libpdal_h3.a"
        "${build_dir_ios}/vendor/arbiter/libpdal_arbiter.a"
        "${build_dir_ios}/vendor/lepcc/libpdal_lepcc.a"
        "${build_dir_ios}/vendor/schema-validator/libpdal_json_schema.a"
        "${curl_prefix}/lib/libcurl.a"
    )
    for v in "${vendor_libs[@]}"; do
        [ -f "${v}" ] || { echo "missing vendor archive: ${v}" >&2; return 1; }
    done

    # Wrap plugin .o files into an archive first; libtool -static
    # accepts .a inputs, not raw .o files.
    local plugin_archive="${stage_ios}/libpdal_plugin_reader_e57.a"
    ar rcs "${plugin_archive}" "${plugin_objdir}"/*.o
    rm -rf "${plugin_objdir}"

    # libtool -static merges everything into one ar archive. Duplicate
    # .o basenames inside (PDAL has Expression.cpp.o in two dirs) are
    # fine — ar archives index by position, not name, and ld resolves
    # via symbols.
    local lib_ios="${stage_ios}/libpdalcpp.a"
    libtool -static -arch_only arm64 \
        -o "${lib_ios}" \
        "${libpdal}" \
        "${vendor_libs[@]}" \
        "${plugin_archive}"
    rm -f "${plugin_archive}"

    # Deliberately NOT including `-headers <dir>` in the xcframework.
    # When SwiftPM consumes a library xcframework with headers, it
    # auto-adds the slice's Headers dir to the consumer's user-include
    # path. That conflicts with consumers that already ship a vendored
    # `pdal/` header tree (e.g. SwiftPDAL's CxxPDAL/include/pdal/),
    # causing redefinition errors on every PDAL type used by both.
    # The xcframework contributes only at link time; consumers bring
    # their own headers.
    rm -rf "${stage_ios}/Headers"

    # Stash proj.db beside the .a so SwiftPDAL consumers can bundle it
    # explicitly in their app target if needed.
    cp "${PROJ_DB_SRC}" "${stage_ios}/proj.db"

    IOS_LIBRARY_ARGS+=( -library "${lib_ios}" )
    echo "iOS/${sdk} library slice: ${lib_ios}"
}

if [ "${SKIP_MACOS:-0}" != "1" ]; then
    build_macos_slice
fi

IOS_LIBRARY_ARGS=()
if [ "${BUILD_IOS:-0}" = "1" ]; then
    : "${PROJ_XCFRAMEWORK:?PROJ_XCFRAMEWORK must be set when BUILD_IOS=1}"
    # E57FORMAT_XCFRAMEWORK defaults to the iOS library artifact
    # produced by build_e57.sh (E57Format-ios.xcframework).
    E57FORMAT_XCFRAMEWORK_RESOLVED="${E57FORMAT_XCFRAMEWORK:-${OUTPUT_DIR}/E57Format-ios.xcframework}"
    [ -d "${E57FORMAT_XCFRAMEWORK_RESOLVED}" ] || {
        echo "E57FORMAT_XCFRAMEWORK not found at ${E57FORMAT_XCFRAMEWORK_RESOLVED}" >&2
        echo "Run ./build_e57.sh <ver> with BUILD_IOS=1 first." >&2
        exit 1
    }
    build_ios_slice device
    build_ios_slice simulator
fi

############################################
step "8/8  Wrap in xcframework(s) + zip"
############################################
# xcodebuild rejects mixed framework + library xcframeworks. We ship
# two artifacts when BUILD_IOS=1:
#   - pdalcpp.xcframework         macOS-only, dynamic framework, unchanged.
#   - pdalcpp-ios.xcframework     iOS device + simulator, static libraries.
# SwiftPDAL declares both binaryTargets with platform-conditional deps.

XC_OUT="${OUTPUT_DIR}/pdalcpp.xcframework"
rm -rf "${XC_OUT}"
xcodebuild -create-xcframework -framework "${FW}" -output "${XC_OUT}"

XC_OUT_IOS=""
if [ "${#IOS_LIBRARY_ARGS[@]}" -gt 0 ]; then
    XC_OUT_IOS="${OUTPUT_DIR}/pdalcpp-ios.xcframework"
    rm -rf "${XC_OUT_IOS}"
    xcodebuild -create-xcframework \
        "${IOS_LIBRARY_ARGS[@]}" \
        -output "${XC_OUT_IOS}"
fi

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp.xcframework"
    cp -R "${XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp.xcframework"
    if [ -n "${XC_OUT_IOS}" ]; then
        rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp-ios.xcframework"
        cp -R "${XC_OUT_IOS}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
        echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp-ios.xcframework"
    fi
fi

cd "${OUTPUT_DIR}"
ZIP="pdalcpp.xcframework.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent pdalcpp.xcframework "${ZIP}"

CHECKSUM=""
if command -v swift >/dev/null 2>&1; then
    CHECKSUM="$(swift package compute-checksum "${ZIP}")"
fi

ZIP_IOS=""
CHECKSUM_IOS=""
if [ -n "${XC_OUT_IOS}" ]; then
    ZIP_IOS="pdalcpp-ios.xcframework.zip"
    rm -f "${ZIP_IOS}"
    ditto -c -k --sequesterRsrc --keepParent pdalcpp-ios.xcframework "${ZIP_IOS}"
    command -v swift >/dev/null 2>&1 && \
        CHECKSUM_IOS="$(swift package compute-checksum "${ZIP_IOS}")"
fi

printf "\n\033[1;32mDONE\033[0m  %s\n" "${XC_OUT}"
printf "      zip: %s\n" "${OUTPUT_DIR}/${ZIP}"
[ -n "${CHECKSUM}" ] && printf "      swift checksum: %s\n" "${CHECKSUM}"
if [ -n "${XC_OUT_IOS}" ]; then
    printf "\n\033[1;32mDONE\033[0m  %s\n" "${XC_OUT_IOS}"
    printf "      zip: %s\n" "${OUTPUT_DIR}/${ZIP_IOS}"
    [ -n "${CHECKSUM_IOS}" ] && printf "      swift checksum: %s\n" "${CHECKSUM_IOS}"
fi

if [ "${RELEASE:-0}" = "1" ]; then
    if [ -z "${GH_RELEASE_REPO:-}" ]; then
        echo "RELEASE=1 set but GH_RELEASE_REPO is empty in config.sh — skipping gh release" >&2
        exit 0
    fi
    TAG="${RELEASE_TAG:-pdal-v${PDAL_VERSION}}"
    TITLE="${RELEASE_TITLE:-PDAL v${PDAL_VERSION} Framework}"
    NOTES="${RELEASE_NOTES:-Binary framework for PDAL v${PDAL_VERSION}}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    release_assets=("${OUTPUT_DIR}/${ZIP}")
    [ -n "${ZIP_IOS}" ] && [ -f "${OUTPUT_DIR}/${ZIP_IOS}" ] \
        && release_assets+=("${OUTPUT_DIR}/${ZIP_IOS}")
    gh release create "${TAG}" "${release_assets[@]}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "${TITLE}" \
        --notes "${NOTES}"
fi
