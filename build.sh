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

############################################
step "8/8  Wrap in xcframework + zip"
############################################
XC_OUT="${OUTPUT_DIR}/pdalcpp.xcframework"
rm -rf "${XC_OUT}"
xcodebuild -create-xcframework -framework "${FW}" -output "${XC_OUT}"

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp.xcframework"
    cp -R "${XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/pdalcpp.xcframework"
fi

cd "${OUTPUT_DIR}"
ZIP="pdalcpp.xcframework.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent pdalcpp.xcframework "${ZIP}"

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
    TAG="pdal-v${PDAL_VERSION}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    gh release create "${TAG}" "${OUTPUT_DIR}/${ZIP}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "PDAL v${PDAL_VERSION} Framework" \
        --notes "Binary framework for PDAL v${PDAL_VERSION}"
fi
