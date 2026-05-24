#!/bin/bash
# Compare two *.framework directories on metadata that matters for binary
# compatibility: install_name, rpaths, dependency list, exported symbols.
# Exits 0 if substantively identical, 1 otherwise.
#
# Usage: ./scripts/diff-frameworks.sh <baseline.framework> <candidate.framework>
#
# Used as a regression guard during the iOS refactor — the macOS slice
# output MUST remain bit-identical-modulo-build-timestamps after each
# phase. Build timestamps and absolute paths in error messages would
# spuriously fail a binary diff, so this compares metadata only.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <baseline.framework> <candidate.framework>" >&2
    exit 2
fi

BASE="$1"
CAND="$2"

[ -d "${BASE}" ] || { echo "baseline not found: ${BASE}" >&2; exit 2; }
[ -d "${CAND}" ] || { echo "candidate not found: ${CAND}" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Find the framework binary (the file named the same as the .framework dir,
# minus the suffix). Works for both Versions/A/X (macOS) and flat X (iOS).
fw_binary() {
    local fw="$1"
    local name
    name="$(basename "${fw}" .framework)"
    if [ -f "${fw}/Versions/A/${name}" ]; then
        echo "${fw}/Versions/A/${name}"
    elif [ -f "${fw}/${name}" ]; then
        echo "${fw}/${name}"
    else
        return 1
    fi
}

# Capture metadata for one binary. Strips absolute paths that vary
# between builds so output is comparable across machines/runs.
capture() {
    local target="$1" out="$2"
    {
        echo "=== otool -L ==="
        otool -L "${target}" | tail -n +2 | awk '{print $1}' | sort
        echo
        echo "=== otool -l LC_RPATH ==="
        otool -l "${target}" | awk '/cmd LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | sort
        echo
        echo "=== otool -l LC_ID_DYLIB ==="
        otool -l "${target}" | awk '/cmd LC_ID_DYLIB/{f=1} f&&/name /{print $2; f=0}'
        echo
        echo "=== nm -gU (defined globals) ==="
        nm -gU "${target}" 2>/dev/null | awk '{print $NF}' | sort -u || true
    } > "${out}"
}

BASE_BIN="$(fw_binary "${BASE}")"
CAND_BIN="$(fw_binary "${CAND}")"

capture "${BASE_BIN}" "${TMP}/base.txt"
capture "${CAND_BIN}" "${TMP}/cand.txt"

if diff -u "${TMP}/base.txt" "${TMP}/cand.txt" > "${TMP}/main.diff"; then
    echo "framework binary metadata identical"
    BIN_OK=1
else
    echo "DIFF in framework binary metadata:"
    cat "${TMP}/main.diff"
    BIN_OK=0
fi

# Compare bundled Libraries/ if either side has them.
BASE_LIBS="${BASE}/Versions/A/Libraries"
CAND_LIBS="${CAND}/Versions/A/Libraries"
[ -d "${BASE_LIBS}" ] || BASE_LIBS="${BASE}/Libraries"
[ -d "${CAND_LIBS}" ] || CAND_LIBS="${CAND}/Libraries"

LIB_OK=1
if [ -d "${BASE_LIBS}" ] || [ -d "${CAND_LIBS}" ]; then
    BASE_LIST="$( [ -d "${BASE_LIBS}" ] && (cd "${BASE_LIBS}" && ls *.dylib 2>/dev/null | sort) || true )"
    CAND_LIST="$( [ -d "${CAND_LIBS}" ] && (cd "${CAND_LIBS}" && ls *.dylib 2>/dev/null | sort) || true )"
    if [ "${BASE_LIST}" != "${CAND_LIST}" ]; then
        echo "DIFF in bundled Libraries/ file list:"
        diff <(echo "${BASE_LIST}") <(echo "${CAND_LIST}") || true
        LIB_OK=0
    else
        for lib in ${BASE_LIST}; do
            capture "${BASE_LIBS}/${lib}" "${TMP}/base-${lib}.txt"
            capture "${CAND_LIBS}/${lib}" "${TMP}/cand-${lib}.txt"
            if ! diff -u "${TMP}/base-${lib}.txt" "${TMP}/cand-${lib}.txt" > "${TMP}/${lib}.diff"; then
                echo "DIFF in Libraries/${lib}:"
                cat "${TMP}/${lib}.diff"
                LIB_OK=0
            fi
        done
        [ "${LIB_OK}" = "1" ] && echo "bundled Libraries/ metadata identical (${BASE_LIST:-none})"
    fi
fi

if [ "${BIN_OK}" = "1" ] && [ "${LIB_OK}" = "1" ]; then
    exit 0
else
    exit 1
fi
