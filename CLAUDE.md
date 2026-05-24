# CLAUDE.md — pdal-xcframework-builder

## Purpose

Standalone tool that builds two xcframeworks from tagged upstream releases:

- `pdalcpp.xcframework` — 3 slices: macOS arm64 (dynamic) + iOS arm64 device (static) + iOS arm64 simulator (static).
- `E57Format.xcframework` — same 3-slice matrix, libE57Format with xerces-c bundled.

iOS slices are opt-in (`BUILD_IOS=1`). The macOS path is unchanged behaviorally from the pre-iOS implementation.

Lives **outside** the PDAL source tree. Sibling project to `gdal-xcframework-builder` and depends on its output (`gdal.xcframework`, plus `proj.xcframework` for iOS).

Both xcframeworks are consumed downstream by `SwiftPDAL` (a Swift Package).

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

## iOS pipeline (build_ios_slice in build.sh; mirror in build_e57.sh)

Opt-in via `BUILD_IOS=1`. macOS phases run unchanged; iOS phases follow, then phase 8 aggregates all slices into one xcframework.

**Build flow per iOS slice:**

1. `scripts/deps/{curl,xerces-c}.sh` cross-compile their respective deps statically into `work/deps-cache/ios-<sdk>/`. Idempotent — skipped if `lib<dep>.a` already present.
2. `cmake` configure with `scripts/toolchain/ios-{device,sim}.cmake`, `BUILD_SHARED_LIBS=OFF` semantics enforced via in-place patch to `libraries.cmake` (see "Upstream patches" below).
3. `cmake --build --target pdalcpp` — restricted to the static library target; `apps/pdal` CLI and `plugins/faux` won't link cleanly under STATIC (CURL::libcurl-NOTFOUND token in their Make rules) and we don't need either binary.
4. Manual artifact staging — `cmake --install` is skipped because `install(EXPORT PDALTargets)` fails under STATIC (vendor static libs missing from export set). We copy `libpdalcpp.a` + source-tree headers + build-tree generated headers directly.
5. Out-of-tree compile of the E57 plugin sources (`src/plugins/e57/io/{E57Reader,E57Writer,Scan,Utils,Uuid}.cpp`) with `clang++ -include scripts/plugin_static_shim.hpp`. The shim redefines `CREATE_SHARED_STAGE` → `CREATE_STATIC_STAGE` so the plugin registers via static-init (same path PDAL's in-tree readers use), no upstream patch to the plugin sources.
6. `ld -r -force_load <archive>` merges into a single MH_OBJECT Mach-O framework binary:
   - `libpdalcpp.a` (PDAL core)
   - 6 PDAL vendor archives (lazperf, kazhdan, h3, arbiter, lepcc, json_schema)
   - Cross-built `libcurl.a` (PDAL's arbiter constructs an HTTP Pool eagerly on startup; `-Wl,-undefined,dynamic_lookup` is NOT a viable shortcut)
   - The 5 plugin `.o` files
7. Flat framework assembly (no `Versions/A` on iOS): `pdalcpp` binary + `Headers/pdal/...` + `Modules/module.modulemap` + `Resources/proj.db` + `Info.plist` (`MinimumOSVersion=17.0`, `CFBundleSupportedPlatforms=[iPhoneOS|iPhoneSimulator]`).
8. Phase 8 then passes all 3 framework paths to `xcodebuild -create-xcframework`.

`build_e57.sh` mirrors this for libE57Format — but only needs xerces-c (no curl, no plugin compile, no apps trickery). Single `ld -r` merges libE57Format + xerces objects.

## Upstream PDAL patches (configure-time, restored on RETURN)

Applied via `sed -i.ios-static.bak` + `trap RETURN`:

1. **`cmake/libraries.cmake`**: `PDAL_LIB_TYPE "SHARED"` → `"STATIC"`. The `set()` lacks `CACHE`, so `-DPDAL_LIB_TYPE=STATIC` is silently clobbered.
2. **`CMakeLists.txt`** (via python, multi-line surgical replacement): comments out `export(TARGETS …)` + `install(EXPORT PDALTargets …)`. Both fail under STATIC and aren't useful downstream — SwiftPDAL doesn't consume PDAL's CMake config.

These mutations happen inside `build_ios_slice` and revert on function exit so the macOS slice (which re-runs CMake on every build) gets the original "SHARED" back.

## Consumer-side requirements (for SwiftPDAL et al)

The iOS framework's `Headers/pdal/...` nested layout breaks the default `<FrameworkName/...>` xcodebuild include convention. Consumers must add an explicit `-I .../pdalcpp.framework/Headers` for `<pdal/StageFactory.hpp>`-style includes to resolve.

iOS consumers must link these system libs / frameworks (none of these ship inside our framework binary):
- `-lz -liconv -lxml2 -lsqlite3 -lc++`
- `-framework Security -framework CoreFoundation -framework SystemConfiguration` (libcurl's SecureTransport TLS runtime deps)

`verify/ios-sample/Package.swift` and SwiftPDAL's `Package.swift` are the canonical consumer examples.

## Out of scope

- Catalyst / visionOS / tvOS / watchOS / x86_64 — untested. iOS arm64 (device + sim) is the new addition; macOS arm64 is the original.
- Patching PDAL source on disk *outside* the build dir — pure orchestrator over upstream tags. The CMake patches above are local to `work/.../src/` and reverted automatically.
- Building GDAL itself — sibling project.
- Publishing libcurl / xerces-c / PROJ as standalone xcframeworks — they're bundled inside ours.
