#!/bin/bash
# One-shot release helper: bundles the four xcframework zips from the
# gdal-xcframework-builder + pdal-xcframework-builder output dirs into a
# single GitHub release on mnmly/SwiftPDAL. Mirrors the existing
# combined-tag pattern (gdal-3.12.4_pdal-2.10.1) — keeps the per-builder
# Makefile `release` targets out of it since they assume per-package tags.
#
# Usage:
#   ./scripts/publish-release.sh [--dry-run] <TAG>
#
#   ./scripts/publish-release.sh --dry-run gdal-3.12.4_pdal-2.10.1-r2
#   ./scripts/publish-release.sh           gdal-3.12.4_pdal-2.10.1-r2
#
# Idempotent on checksum computation; gh release create is NOT idempotent
# (re-running on the same tag will error). Delete the release in GH UI
# first if you need to retag.
set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

TAG="${1:-}"
if [ -z "${TAG}" ]; then
    echo "Usage: $0 [--dry-run] <tag>" >&2
    echo "Example: $0 gdal-3.12.4_pdal-2.10.1-r2" >&2
    exit 2
fi

REPO="mnmly/SwiftPDAL"

# Resolve paths relative to this script's parent (the builder root).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GDAL_BUILDER="$(cd "${ROOT}/../gdal-xcframework-builder" && pwd)"

ASSETS=(
    "${GDAL_BUILDER}/output/gdal.xcframework.zip"
    "${GDAL_BUILDER}/output/proj.xcframework.zip"
    "${ROOT}/output/pdalcpp.xcframework.zip"
    "${ROOT}/output/E57Format.xcframework.zip"
)

for a in "${ASSETS[@]}"; do
    [ -f "${a}" ] || { echo "missing asset: ${a}" >&2; exit 1; }
done

echo "Tag:    ${TAG}"
echo "Repo:   ${REPO}"
echo "Assets:"
for a in "${ASSETS[@]}"; do
    printf "  %s\n" "${a}"
done
echo

# Swift Package Manager checksums so Package.swift can verify integrity.
echo "Computing Swift package checksums..."
for a in "${ASSETS[@]}"; do
    local_name="$(basename "${a}")"
    cksum="$(swift package compute-checksum "${a}")"
    printf "  %-30s %s\n" "${local_name}" "${cksum}"
done
echo

if [ "${DRY_RUN}" = "1" ]; then
    echo "DRY RUN — not creating GitHub release."
    echo "Re-run without --dry-run to publish."
    exit 0
fi

NOTES="iOS-enabled binary frameworks (macOS arm64 dynamic + iOS arm64 device static + iOS arm64 simulator static).

- gdal.xcframework — GDAL 3.12.4
- proj.xcframework — PROJ 9.4.0 (iOS-only artifact)
- pdalcpp.xcframework — PDAL 2.10.1 with E57 reader statically linked, libcurl + xerces-c + all PDAL vendor archives merged
- E57Format.xcframework — libE57Format 3.3.0 with xerces-c 3.3.0 bundled

Built by gdal-xcframework-builder + pdal-xcframework-builder.
"

echo "Creating GitHub release..."
gh release create "${TAG}" \
    --repo "${REPO}" \
    --title "GDAL 3.12.4 + PDAL 2.10.1 — Apple platforms (r2)" \
    --notes "${NOTES}" \
    "${ASSETS[@]}"

echo
echo "Done. Update SwiftPDAL Package.swift with URLs of the form:"
echo "  https://github.com/${REPO}/releases/download/${TAG}/<asset>.zip"
echo "and the swift checksums printed above."
