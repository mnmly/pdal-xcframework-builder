# CLAUDE.md — pdal-xcframework-builder

## Purpose

Standalone tool that builds a `pdalcpp.xcframework` for macOS (arm64) from any tagged upstream PDAL release. Lives **outside** the PDAL source tree. Sibling project to `gdal-xcframework-builder` and depends on its output.

The xcframework is consumed downstream by `SwiftPDAL` (a Swift Package).

## Why this is more involved than the GDAL builder

PDAL's CMake **does not natively emit a `.framework` on install** — only a regular dylib + headers + cmake exports. The user has a `feature/framework-build` branch on their fork (mnmly/PDAL) that adds a `cmake/framework.cmake`, but it's an orphan file (never `include()`d), so even on that branch the install isn't a framework. The previous working `pdalcpp.framework` was assembled by hand and the recipe was lost.

This builder reproduces the framework structure entirely in shell after a normal install, so it works against any upstream PDAL tag without depending on the user's fork or branch state.

## Pipeline (build.sh, 8 phases)

1. **Fetch** — clone upstream PDAL at tag (auto-detects `<version>` or `v<version>` via `git ls-remote`; override with `PDAL_TAG`).
2. **Configure** — standard install layout (no framework cmake). Links against:
   - `-DGDAL_DIR=${GDAL_XCFRAMEWORK}/macos-arm64/gdal.framework/Versions/Current/lib/cmake/gdal`
   - `-DPROJ_DIR=${PROJ_PREFIX}/lib/cmake/proj`
   - `-DCMAKE_IGNORE_PATH="/opt/homebrew;/usr/local"` (forces use of the supplied GDAL, not Homebrew's)
   - `-DCMAKE_FIND_FRAMEWORK=LAST`
3. **Build + install** into `work/.../install` (`lib/libpdalcpp.X.Y.Z.dylib`, `include/pdal/...`, `bin/pdal-config`, plugins in `lib/`).
4. **Assemble framework** at `work/.../stage/pdalcpp.framework`:
   - `Versions/A/pdalcpp` ← `lib/libpdalcpp.X.Y.Z.dylib`, with `install_name_tool -id "@rpath/pdalcpp.framework/Versions/A/pdalcpp"`
   - SOVERSION-derived symlinks `libpdalcpp.<X>.dylib`, `libpdalcpp.dylib` → `pdalcpp` (so plugins linked to old soname still resolve)
   - `Versions/A/Headers/pdal/` ← `install/include/pdal/` (preserves nested layout — `pdal/` subdir is intentional)
   - `Versions/A/Modules/module.modulemap` ← shipped at `resources/module.modulemap` in this repo
   - `Versions/A/PlugIns/*.dylib` ← `install/lib/libpdal_plugin_*.dylib`, with their `@rpath/libpdalcpp.X.dylib` refs rewritten to `@rpath/pdalcpp.framework/Versions/A/pdalcpp` and an `@loader_path/../../..` rpath added so plugin dlopen resolves the framework
   - `Versions/A/Resources/proj.db` ← `${PROJ_PREFIX}/share/proj/proj.db`
   - `Versions/A/Resources/Info.plist` written fresh via heredoc (`CFBundleVersion=${PDAL_VERSION}`, `CFBundleIdentifier=org.osgeo.pdalcpp`, etc.) and `plutil -lint`ed
5. **Bundle deps + rpath fixup** — `dylibbundler -od -b -x ./pdalcpp.framework/Versions/A/pdalcpp -d Versions/A/Libraries/ -p @loader_path/Libraries/ -s ${DYLIBBUNDLER_SEARCH_PATHS}`, then per-dylib rpath normalisation loop (collapse duplicate LC_RPATHs, ensure `@loader_path`, rewrite `@loader_path/Libraries/<name>` → `@loader_path/<name>`).
6. **Top-level symlinks** — `pdalcpp`, `Headers`, `Modules`, `Libraries`, `Resources`, `PlugIns` → `Versions/Current/...`; `Versions/Current → A`.
7. **Codesign (optional)** — only if `CODESIGN_IDENTITY` set. Usually unnecessary; Xcode re-signs on Embed & Sign.
8. **xcframework + zip** — `xcodebuild -create-xcframework`, `ditto` zip, `swift package compute-checksum`. Optional `gh release create` if `RELEASE=1` and `GH_RELEASE_REPO` set.

## Files

- `build.sh` — orchestrator
- `resources/module.modulemap` — bundled into the framework's `Modules/`. Edit to change Swift import surface.
- `Makefile` — `xcframework`, `release`, `clean`, `distclean`
- `config.sh.example` — template (user copies to `config.sh`, gitignored)
- `work/`, `output/` — gitignored

## Config knobs (config.sh)

- `GDAL_XCFRAMEWORK` (**required** — path to gdal.xcframework from sibling builder)
- `PROJ_PREFIX` (default `brew --prefix proj@9`)
- `CODESIGN_IDENTITY` (optional)
- `OUTPUT_DIR` (default `./output`)
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` (optional mirror dest)
- `GH_RELEASE_REPO` (for `make release`)
- `ARCHS` (default `arm64`)
- `DEPLOYMENT_TARGET` (default `26.0`)
- `ENABLED_PLUGINS` (default `E57`)
- `PDAL_TAG` (override tag auto-detection)
- `EXTRA_CMAKE_FLAGS`
- `DYLIBBUNDLER_SEARCH_PATHS` (default includes homebrew lib + expat + xerces-c)

## Known issues fixed vs. the user's previous hand-built framework

- **Doubled install_name**: existing framework had `@rpath/pdalcpp.framework/Versions/A/pdalcpp/pdalcpp.framework/Versions/A/pdalcpp`. Fixed to single `@rpath/pdalcpp.framework/Versions/A/pdalcpp`.
- **Smart-quote `Info.plist` bug**: original notes copy-pasted curly quotes (`"2.9.3"` showed up as `"“2.9.3”"`). Heredoc generation eliminates it.
- **Absolute Homebrew links**: existing framework had `/opt/homebrew/opt/gdal/lib/libgdal.38.dylib` baked in, making it unportable. New build links against the supplied GDAL xcframework via `@rpath` and bundles other deps via `dylibbundler`.

## Conventions and gotchas

- **PDAL doesn't natively make a framework.** Don't try to enable `BUILD_FRAMEWORK` flags or expect cmake `FRAMEWORK DESTINATION` to do the work — they don't.
- **`proj.db` step is essential.** Runtime CRS/datum lookups fail silently or return wrong values without it.
- **`expat` must be brew-installed** (same trap as the GDAL builder — system expat lives in dyld_shared_cache, no on-disk file for `dylibbundler` to copy). Preflight check enforces this.
- **`xerces-c`** is a likely transitive dep (used by E57 plugin). Already in `DYLIBBUNDLER_SEARCH_PATHS` defaults.
- **`Headers/pdal/` nested layout is deliberate** — matches the existing framework + the umbrella header path expected by `module.modulemap`. Don't flatten.
- **Plugin linkage is best-effort.** `install_name_tool -change` rewrites `@rpath/libpdalcpp.X.dylib` refs and adds an rpath to the plugins. If a plugin fails to load at runtime, this is the first place to look.
- **Tag format** varies in PDAL history. Auto-detection via `git ls-remote` handles `2.x.y` and `v2.x.y`.
- **`CMAKE_OSX_DEPLOYMENT_TARGET=26.0`** is high. Keep it aligned with the GDAL builder's setting.
- **`CMAKE_IGNORE_PATH=/opt/homebrew;/usr/local`** is intentional — forces PDAL to find GDAL in the supplied xcframework rather than Homebrew's.
- **`set -euo pipefail`** is on.

## Relationship to gdal-xcframework-builder

- This builder **consumes** the output of that one. Build GDAL first, then PDAL.
- Both share the same shape (`config.sh`, numbered `build.sh` phases, Makefile targets, work/output dirs) — keep stylistically aligned when changing one.
- Both default to **no codesign** (Xcode re-signs on Embed & Sign).

## When the user asks for changes

- **Edit module map**: change `resources/module.modulemap`. It gets copied verbatim into the framework.
- **Bump deployment target / plugins / proj version**: edit `config.sh.example` and confirm GDAL was built against the same target.
- **Adding/removing assembly steps in phase 4**: keep the `Versions/A/...` structure intact — Swift consumers and codesign both depend on the standard layout.
- **A new transitive dep prompts dylibbundler**: `brew install` it, add its lib dir to `DYLIBBUNDLER_SEARCH_PATHS`.

## Out of scope

- iOS / Catalyst / x86_64 — untested.
- Patching PDAL source — pure orchestrator over upstream tags. The user's `feature/framework-build` branch on mnmly/PDAL is intentionally **not** consumed; if it lands upstream and gets wired in, this builder can be simplified.
- Building GDAL itself — sibling project.
