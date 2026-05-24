# Plan — extend pdal-xcframework-builder to ship iOS slices

> **Audience:** the agent receiving this task. You will not have the planning
> conversation in your context. This document is the full spec. Read top to
> bottom before touching code.

---

## 1. Context

This repo orchestrates **two** xcframeworks from tagged upstream releases:

- `build.sh` → `pdalcpp.xcframework` (PDAL core)
- `build_e57.sh` → `E57Format.xcframework` (libE57Format + bundled xerces-c)

See `CLAUDE.md` for the existing macOS pipelines (8 / 9 phases) and their
known gotchas — they all still apply for the macOS slice.

**Downstream consumers (both local on this machine):**

- `/Users/mnmly/Development-local/Personal/SwiftPDAL` — Swift Package that
  depends on `pdalcpp.xcframework`, `E57Format.xcframework`, and
  `gdal.xcframework` as `.binaryTarget`s. Currently macOS-only.
- `gdal-xcframework-builder` (sibling) — producer of `gdal.xcframework` and
  (new in its Phase 1) `proj.xcframework`. See its
  `tasks/todo.md` for the exact shapes this builder consumes.

**Why this work:** SwiftPDAL needs iOS. The GDAL-side builder is being
extended in parallel to ship iOS slices of `gdal.xcframework` (3 slices)
and a new `proj.xcframework` (iOS-only, 2 slices). This builder must do
the same for `pdalcpp.xcframework` and `E57Format.xcframework`. **E57
support on iOS is mandatory from day one — no "skip on iOS" shortcut.**

### Recon already done — don't redo

- `build.sh` and `build_e57.sh` already exist as macOS-arm64 dynamic
  pipelines. Both end with `xcodebuild -create-xcframework` over a single
  framework. We need to extend each to emit 3-slice xcframeworks.
- This builder consumes:
  - `gdal.xcframework` (macOS-arm64 dynamic + ios-arm64 static + ios-arm64-sim static)
  - `proj.xcframework` (NEW iOS-only; ios-arm64 static + ios-arm64-sim static)
    — macOS continues to use Homebrew PROJ via `PROJ_PREFIX`.
  - `E57Format.xcframework` (produced by **this** repo's `build_e57.sh`).
- PDAL's CMake does NOT natively emit a framework on install. macOS slice
  hand-assembles one in phase 4 of `build.sh`. Same approach for iOS, but
  flat layout (no `Versions/A`) and static archive instead of dylib.
- PDAL's E57 reader is normally a loadable plugin
  (`libpdal_plugin_reader_e57.dylib`). For static iOS builds it must be
  linked into `libpdalcpp.a`. **Plugin static-linking strategy is a
  Phase-0 spike — see §6.**

---

## 2. Goal

**`pdalcpp.xcframework`** — three slices:

| Slice                | SDK              | Link mode  |
| -------------------- | ---------------- | ---------- |
| macOS arm64          | `macosx`         | dynamic    |
| iOS arm64 device     | `iphoneos`       | **static** |
| iOS arm64 simulator  | `iphonesimulator`| **static** |

**`E57Format.xcframework`** — three slices, same matrix.

macOS slices must remain behaviorally identical to current output —
existing consumers depend on the dynamic-framework + bundled-dylibs
(macOS pdalcpp) and dynamic-framework + bundled-xerces (macOS E57Format)
shapes.

iOS slices are arm64-only, static, with **all transitive C++ deps
merged into a single Mach-O archive per framework binary**. Public
headers + a framework `module.modulemap` ship inside each. No `Versions/`
symlink dance on iOS — flat framework layout (`gdal.framework/gdal`,
`gdal.framework/Headers/`, etc.).

---

## 3. Decisions already made — DO NOT re-litigate

If you believe one of these is wrong, surface it via §9 (open questions)
before deviating — don't silently re-decide.

| Decision                    | Value | Why |
| --------------------------- | ----- | --- |
| Phase 1 platforms           | macOS + iOS only. No tvOS/visionOS/watchOS/Catalyst. | Matches GDAL builder Phase 1; SwiftPDAL needs iOS today. |
| x86_64                      | Dropped entirely. arm64 everywhere. | Matches GDAL builder. |
| iOS link mode               | Static (single merged archive per slice, per framework). | App Store rejects iOS frameworks with embedded dylibs. macOS keeps dynamic. |
| iOS deployment target       | **17.0** | Matches GDAL builder. Don't lower without asking. |
| E57 on iOS                  | **Required from day one — statically linked.** | User non-negotiable. No "skip E57 on iOS" path. |
| PDAL plugins on iOS         | Only E57. Other plugins disabled. | Plugin dlopen doesn't work in static iOS; E57 is the only one we need. |
| `pdal` / `pdal-config` CLI  | macOS only. iOS slice = library only. | CLIs don't ship on iOS. |
| Cross-repo edits            | You MAY edit SwiftPDAL if needed. | User authorized. Present diffs together. |
| Codesign                    | Off by default on iOS slices too. | Xcode re-signs on Embed & Sign. |
| Dep packaging               | **xerces merged into E57Format static archive on iOS** (same pattern as macOS where xerces is bundled in Libraries/). | Self-contained iOS framework. |
| PROJ source (macOS)         | Homebrew (`PROJ_PREFIX`), unchanged. | Status quo. |
| PROJ source (iOS)           | New `PROJ_XCFRAMEWORK` config knob → iOS slice of `proj.xcframework`. | GDAL builder owns the artifact. |
| Order of operations         | `build_e57.sh` MUST run before `build.sh` iOS slices (PDAL E57 plugin links libE57Format). | Same as macOS today. |
| Both build scripts share toolchain files | Single `scripts/toolchain/ios-{device,sim}.cmake` used by both. | Avoid drift between the two. |

---

## 4. Acceptance criteria

A task is "done" when ALL of these hold:

1. `./build_e57.sh 3.3.0` produces `output/E57Format.xcframework` with
   exactly 3 slices in its `Info.plist`.
2. `./build.sh <PDAL_VERSION>` produces `output/pdalcpp.xcframework` with
   exactly 3 slices in its `Info.plist`.
3. Both macOS slices are behaviorally identical to a `main`-baseline
   build (compare `otool -L`, `otool -l`, `nm -gU` of the framework
   binary and bundled Libraries/). Diff harness in `scripts/`.
4. A minimal iOS sample app (under `verify/ios-sample/`) imports both
   frameworks, calls `pdal::Stage` construction and reads an E57 file,
   and runs in the iOS Simulator from the command line
   (`xcodebuild -destination 'generic/platform=iOS Simulator,...'`).
5. `make distclean && make` from a clean tree (deps cache also cleared)
   succeeds on a stock M-series Mac with documented prerequisites.
6. `swift package compute-checksum` produces a checksum for each zipped
   xcframework.
7. SwiftPDAL state reported (§9). If `Package.swift` needs `.iOS(...)`,
   either updated or surfaced as a checklist.
8. `tasks/lessons.md` updated with any new pitfalls discovered.

---

## 5. Architecture

### 5.1 Per-script per-slice layout

```
build_e57.sh
  ├── build_macos_slice()   ← existing 9-phase body, refactored intact
  └── build_ios_slice(sdk)  ← new: xerces-c static → libE57Format static →
                              libtool -static merge → flat framework

build.sh
  ├── build_macos_slice()   ← existing 8-phase body, refactored intact
  └── build_ios_slice(sdk)  ← new: PDAL static configure (consuming
                              gdal/proj/E57Format iOS slices) → libtool
                              -static merge (libpdalcpp.a + E57 plugin
                              objects) → flat framework
```

### 5.2 Static framework shape (iOS only)

```
pdalcpp.framework/             ← flat, no Versions/
  pdalcpp                       ← merged static Mach-O archive
  Headers/pdal/...              ← matches macOS nested layout
  Info.plist                    ← MinimumOSVersion=17.0, CFBundleSupportedPlatforms set
  Modules/module.modulemap      ← from resources/, unchanged
  Resources/proj.db             ← still shipped; runtime CRS lookups
```

```
E57Format.framework/           ← flat
  E57Format                     ← libE57Format + xerces-c merged static archive
  Headers/                      ← flattened from libE57Format install (matches macOS)
  Info.plist
  Modules/module.modulemap      ← matches macOS modulemap content
```

### 5.3 deps-cache layout (iOS-only deps owned by THIS repo)

```
work/
  deps-cache/
    ios18-device/
      xerces-c-3.3.0/
        lib/libxerces-c.a
        include/xercesc/...
    ios18-simulator/
      <same>
```

Cache key is `<dep>-<version>` inside `<sdk-major>-<variant>/`. Same
pattern as gdal-xcframework-builder. PROJ, gdal, and (consumed)
E57Format come in as full xcframeworks via config knobs — not in
deps-cache.

### 5.4 PDAL iOS configure — key flags

```bash
cmake -S "${SRC_DIR}" -B "${BUILD_DIR_IOS}" \
  -DCMAKE_TOOLCHAIN_FILE="${ROOT}/scripts/toolchain/ios-<sdk>.cmake" \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR_IOS}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_PDAL_APPS=OFF -DBUILD_TESTING=OFF \
  -DBUILD_PLUGIN_E57=ON \
  -DGDAL_DIR="${GDAL_XCFRAMEWORK}/ios-arm64[_simulator]/gdal.framework/lib/cmake/gdal" \
  -DPROJ_DIR="${PROJ_XCFRAMEWORK}/ios-arm64[_simulator]/proj.framework/lib/cmake/proj" \
  -DE57Format_DIR=...  # see §6 Phase 0 spike
  -DCMAKE_PREFIX_PATH=... \
  ...
```

Exact `E57Format_DIR` path TBD by Phase 0 spike (depends on whether the
iOS E57Format.framework ships a CMake config; macOS one may or may not).

---

## 6. Phased work breakdown

> Treat each phase as independently committable. Run the existing macOS
> builds between phases to catch regressions. After each phase, write a
> short progress note under §10.

### Phase 0 — baseline + spikes (1 day)

**Baseline harness:**
- [ ] Run `./build.sh <CUR>` and `./build_e57.sh <CUR>` on `main`. Save
      outputs to `verify/baseline/` (gitignored).
- [ ] Capture `otool -L`, `otool -l`, `nm -gU` of macOS framework
      binaries + bundled Libraries/dylibs.
- [ ] Add `scripts/diff-frameworks.sh` — compares two framework paths
      on metadata above, exits nonzero on substantive diffs. Used as a
      regression check after every phase.
- [ ] Seed `tasks/lessons.md`.

**Static E57 plugin spike (critical — block before Phase 5):**
- [ ] Read PDAL's `plugins/e57/CMakeLists.txt` at the target tag.
- [ ] Determine what happens when `BUILD_SHARED_LIBS=OFF` +
      `BUILD_PLUGIN_E57=ON`. Hypotheses to verify:
      - (a) CMake emits `libpdal_plugin_reader_e57.a` automatically.
      - (b) CMake still emits a SHARED MODULE target (broken on iOS).
      - (c) Plugin sources are unconditionally compiled into a SHARED
            target with no static option.
- [ ] If (a): great, just merge it into `libpdalcpp.a` via libtool.
- [ ] If (b)/(c): two options —
      - Compile the plugin's `.cpp` files into a sibling static lib in
        our build (out-of-tree CMake call against the plugin's source
        dir), or
      - Patch PDAL's CMakeLists at install time (sed-style, kept
        minimal — record in lessons.md).
- [ ] Document the chosen approach in `tasks/lessons.md`.

**E57Format CMake config spike:**
- [ ] Check whether `${E57_INSTALL}/lib/cmake/E57Format/E57FormatConfig.cmake`
      exists post-install on macOS today. If yes, replicate the layout
      inside the iOS framework so PDAL's `find_package(E57Format)` works.
      If no, fall back to `-DE57Format_INCLUDE_DIR` / `-DE57Format_LIBRARY`
      explicit flags.

### Phase 1 — refactor + skeleton (½ day)

- [ ] Refactor `build.sh` and `build_e57.sh` to wrap their existing
      bodies in `build_macos_slice()` functions. Behavior unchanged.
      Verify with `diff-frameworks.sh`.
- [ ] Extend `config.sh.example`:
      - `BUILD_IOS=0` (default off; opt-in for now)
      - `IOS_DEPLOYMENT_TARGET=17.0`
      - `PROJ_XCFRAMEWORK=` (required when `BUILD_IOS=1`)
      - `E57FORMAT_XCFRAMEWORK=` (auto-defaults to
        `${OUTPUT_DIR}/E57Format.xcframework` if unset)
- [ ] Create `scripts/toolchain/ios-device.cmake` and
      `scripts/toolchain/ios-sim.cmake` (see GDAL builder plan §Phase 4
      for content — copy verbatim, adjust deployment target if needed).
- [ ] Add `scripts/deps/xerces-c.sh` stub (callable as
      `./scripts/deps/xerces-c.sh <sdk> <install_prefix>`).

### Phase 2 — xerces-c cross-compile (½ day)

- [ ] `scripts/deps/xerces-c.sh`: shallow-clones xerces-c at
      `${XERCES_VERSION}` to `work/src-deps/xerces-c-<ver>/`, configures
      with the iOS toolchain, `BUILD_SHARED_LIBS=OFF`, `-Dnetwork=OFF`,
      `-Dtranscoder=iconv`, installs to
      `work/deps-cache/<sdk>/xerces-c-<ver>/`.
- [ ] Idempotent: skip if `lib/libxerces-c.a` already there.
- [ ] Validate: `lipo -info libxerces-c.a` reports arm64 only;
      `vtool -show-build` on a member object confirms correct platform.

### Phase 3 — build_e57.sh iOS slices (1 day)

For each iOS slice:
- [ ] Build xerces-c via `scripts/deps/xerces-c.sh`.
- [ ] Cross-build libE57Format static against deps-cache xerces:
      `BUILD_SHARED_LIBS=OFF`, `CMAKE_PREFIX_PATH=${DEPS_CACHE}/xerces-c-<ver>`,
      install to `work/e57-<ver>/install-ios-<sdk>/`.
- [ ] Assemble flat `E57Format.framework`:
      - `libtool -static -arch_only arm64 -o E57Format libE57Format.a libxerces-c.a`
      - Flatten headers from `install/include/E57Format/` → `Headers/`.
      - Write `Info.plist` (CFBundleSupportedPlatforms set; MinimumOSVersion 17.0).
      - Write `Modules/module.modulemap` (same content as macOS — `requires cplusplus`).
- [ ] Update `build_e57.sh`'s phase 9 to pass all 3 frameworks to
      `xcodebuild -create-xcframework`.

### Phase 4 — build.sh iOS slices (1.5 days)

For each iOS slice:
- [ ] Resolve `GDAL_DIR`, `PROJ_DIR`, `E57Format_*` paths from the
      consumed xcframeworks.
- [ ] Apply the Phase-0 static-plugin strategy.
- [ ] Configure PDAL: `BUILD_SHARED_LIBS=OFF`, `BUILD_PDAL_APPS=OFF`,
      `BUILD_TESTING=OFF`, `BUILD_PLUGIN_E57=ON`, toolchain file, deps
      flags. Drop `CMAKE_IGNORE_PATH` and `CMAKE_FIND_FRAMEWORK` —
      those are macOS-specific.
- [ ] `gen_version_h` workaround equivalent if PDAL has a similar
      configure-time header issue (check during spike).
- [ ] Build + install.
- [ ] `libtool -static -arch_only arm64 -o pdalcpp libpdalcpp.a <plugin .a>`
      Merge list: PDAL's own static archive plus the E57 reader plugin's
      static archive (from Phase 0 spike).
- [ ] Assemble flat `pdalcpp.framework`:
      - Copy headers preserving `Headers/pdal/...` nested layout.
      - Copy `resources/module.modulemap` to `Modules/`.
      - Ship `proj.db` in `Resources/` (consumed from
        `${PROJ_XCFRAMEWORK}` iOS slice Resources, or fall back to
        `${PROJ_PREFIX}/share/proj/proj.db` if iOS proj.xcframework
        embeds via `EMBED_PROJ_DATA=ON` and doesn't ship the file).
      - Write `Info.plist`, `plutil -lint`.

### Phase 5 — xcframework assembly (20 min)

- [ ] `build_e57.sh` phase 9: 3-framework `xcodebuild -create-xcframework`.
- [ ] `build.sh` phase 8: 3-framework `xcodebuild -create-xcframework`.
- [ ] `xcodebuild` rejects overlapping (platform, variant) tuples — any
      duplicate-slice bug surfaces here loudly.
- [ ] Zip + `swift package compute-checksum` for both, unchanged.

### Phase 6 — verification (½ day)

- [ ] `verify/ios-sample/` — minimal Swift target that imports `pdalcpp`
      and `E57Format`, constructs a `pdal::StageFactory`, opens a small
      bundled E57 file, prints scan count. Builds via
      `xcodebuild -destination 'generic/platform=iOS Simulator,name=iPhone 15'`.
- [ ] `make verify-ios` target: device build (compile-only) + simulator
      build (compile + run smoke).
- [ ] Run `scripts/diff-frameworks.sh` against the new macOS slices —
      MUST be no-op.

### Phase 7 — SwiftPDAL coordination (½ day; cross-repo)

Inspect `/Users/mnmly/Development-local/Personal/SwiftPDAL/Package.swift`:
- [ ] Add `.iOS("17.0")` to `platforms:`.
- [ ] Update `pdalcpp` + `E57Format` binary targets to point at new
      artifacts (URL + checksum once published, or `path:` for local
      iteration).
- [ ] Verify a new `proj` binary target is declared (the GDAL builder's
      Phase 10 may already handle this — coordinate, don't duplicate).
- [ ] Build SwiftPDAL for iOS Simulator from the command line to confirm
      end-to-end success.

### Phase 8 — docs + release (½ day)

- [ ] Update `README.md` with iOS instructions, prerequisites.
- [ ] Update `CLAUDE.md`: remove iOS from "Out of scope"; add "iOS
      pipeline" sections to both `build.sh` and `build_e57.sh` notes.
- [ ] Append discovered pitfalls to `tasks/lessons.md`.
- [ ] DO NOT cut a GitHub release. User reviews locally first.

---

## 7. Working notes / discoveries section

> Append findings here as you go.

(empty — fill during implementation)

---

## 8. Known pitfalls — read before coding

### Carried from CLAUDE.md (still apply for macOS slice)

1. PDAL's CMake doesn't natively make a framework. Don't try
   `BUILD_FRAMEWORK` flags.
2. `proj.db` step is essential — runtime CRS lookups fail silently
   without it.
3. macOS `expat` and `xerces-c` come from Homebrew; iOS gets xerces from
   our cross-build, doesn't need expat (proj has its own iOS dep tree).
4. macOS `Headers/pdal/` nested layout is deliberate. iOS keeps it.
5. macOS plugin linkage is best-effort via `install_name_tool -change`
   — N/A on iOS (static).
6. PDAL tag format varies — auto-detection handles `2.x.y` and `v2.x.y`.
7. `set -euo pipefail` is on.

### From the GDAL builder plan (apply here too)

8. `CMAKE_OSX_DEPLOYMENT_TARGET` must be set BEFORE `project()`. Use
   toolchain file.
9. `try_run` fails in cross-compile — pre-cache endianness etc.
10. iOS framework Mach-O type is `MH_OBJECT` for static. Don't try
    `install_name_tool -id` a static archive.
11. App Store validation rejects iOS frameworks containing dylibs.
    Static merge is the only safe shape.
12. `xcodebuild -create-xcframework` rejects overlapping
    (platform, variant) tuples.
13. Simulator binaries on Apple Silicon ARE arm64. Differ from device
    by `LC_BUILD_VERSION` tag. Check with `vtool -show-build`.
14. Don't merge libc++.a — part of iOS SDK.
15. `dylibbundler` MUST NOT run on iOS slices — macOS-only tooling.
    Guard existing calls in `build.sh:230` and `build_e57.sh:235`.

### New PDAL/E57-specific pitfalls

16. **PDAL E57 plugin is a SHARED MODULE on macOS.** For iOS static,
    we need either CMake-emitted static plugin lib, an out-of-tree
    plugin-source compile, or a minimal upstream patch. Phase 0 spike
    decides — record outcome in `tasks/lessons.md`.
17. **PDAL has many other plugins** (PostgreSQL, Oracle, MBIO, etc.).
    Disable all except E57 on iOS via `-DBUILD_PLUGIN_*=OFF`. Audit
    PDAL's CMake options before assuming `BUILD_PLUGIN_E57=ON` is the
    only flag needed.
18. **PDAL pulls libgdal symbols transitively.** In the iOS static
    framework, libgdal lives in `gdal.xcframework` (not merged into
    pdalcpp). Consumers must link `pdalcpp + gdal + proj + E57Format`
    together — same model as macOS, just static. Document in README.
19. **`proj.db` provenance on iOS.** GDAL builder uses
    `EMBED_PROJ_DATA=ON` for iOS PROJ — proj.db may not be in the
    proj.xcframework Resources at all. PDAL's runtime might still
    expect a `proj.db` file. Verify during Phase 4; if needed, copy
    from `${PROJ_PREFIX}/share/proj/proj.db` (host Homebrew) into the
    iOS `pdalcpp.framework/Resources/`.
20. **libE57Format header layout.** macOS `build_e57.sh` flattens
    `include/E57Format/*.h` into `Headers/`. iOS slice must match
    exactly — modulemap umbrella header is `E57Format.h` and breaks
    if nested.
21. **PDAL's `gen_version_h` analog.** Check during Phase 0 whether
    PDAL has a similar configure-time generated header that breaks
    in cross-compile.

---

## 9. Open questions to surface BEFORE marking done

Surface these to the user via a single batched question:

1. **Verification depth.** Phase 6's smoke test is "open a small E57
   file, print scan count." Is that sufficient, or do we want a full
   COPC write round-trip via the SwiftPDAL bridge? (Recommend: scan
   count is fine for Phase 1.)
2. **Test asset.** We need a small E57 file checked into
   `verify/ios-sample/Resources/` (or git-lfs'd). Ask user for one,
   or generate a synthetic 1-scan file at build time?
3. **Release artifact.** User reviews locally first per §6 Phase 8.
   Confirm before publishing any GitHub release.
4. **Static-plugin strategy outcome.** If Phase 0 spike concludes we
   need an upstream PDAL patch, that's a non-trivial deviation from
   the "pure orchestrator over upstream tags" stance documented in
   `CLAUDE.md`. Confirm direction with user before patching.

---

## 10. Progress log

> Append entries as you complete phases. Format:
> `## YYYY-MM-DD — Phase N: <one-line summary>`

## 2026-05-24 — Phase 0: spikes resolved

- Static E57 plugin: out-of-tree compile + force-included shim (`scripts/plugin_static_shim.hpp`, written in Phase 4). Zero upstream patches. Details: `tasks/lessons.md`.
- E57Format CMake-config concern is moot: PDAL plugin uses `add_subdirectory(libE57Format)`, not `find_package(E57Format)`. With `-DBUILD_PLUGIN_E57=OFF` PDAL skips libE57Format entirely; our out-of-tree compile pulls headers + static archive from our own `E57Format.xcframework` iOS slice.
- Plugin sources don't include `xercesc` directly — xerces stays libE57Format's internal detail.

## 2026-05-24 — Phase 1: refactor + skeleton

- `build.sh` phases 2–7 wrapped in `build_macos_slice()`; phase 1 (Fetch) and phase 8 (xcframework) stay outside.
- `build_e57.sh` phases 1–8 wrapped in `build_macos_slice()`; phase 9 stays outside.
- `scripts/toolchain/ios-{device,sim}.cmake` written (deployment target 17.0, aligned with gdal builder).
- `scripts/deps/xerces-c.sh` stub created (body in Phase 2).
- `scripts/diff-frameworks.sh` regression harness written. Self-test passes against current output.
- `verify/baseline/{pdalcpp,E57Format}.xcframework` snapshotted from existing macOS output.
- `verify/` added to `.gitignore`.
- `config.sh.example` gains: `BUILD_IOS`, `IOS_DEPLOYMENT_TARGET`, `PROJ_XCFRAMEWORK`, `E57FORMAT_XCFRAMEWORK`.
- E57 macOS rebuild: diff harness no-op. ✓
- PDAL macOS rebuild: diff harness clean once baseline updated for host Homebrew PROJ patch bump. ✓

## 2026-05-24 — Phase 2: xerces-c cross-compile

- `scripts/deps/xerces-c.sh` complete. Idempotent. Shared source clone under `work/src-deps/xerces-c-<ver>/`.
- Both slices built and verified:
  - `work/deps-cache/ios-device/xerces-c-3.3.0/lib/libxerces-c.a` — `platform IOS, minos 17.0`
  - `work/deps-cache/ios-simulator/xerces-c-3.3.0/lib/libxerces-c.a` — `platform IOSSIMULATOR, minos 17.0`
- Gotcha logged: xerces-c samples need `CMAKE_MACOSX_BUNDLE=OFF` on iOS. See `tasks/lessons.md`.

## 2026-05-24 — Phase 3: build_e57.sh iOS slices

- `build_ios_slice(sdk)` added. Function builds xerces-c → libE57Format static → merges via `ld -r` into a single MH_OBJECT Mach-O.
- `output/E57Format.xcframework` now ships 3 slices:
  - macos-arm64 (dynamic, identical to baseline ✓)
  - ios-arm64 (static, MH_OBJECT, platform IOS, minos 17.0)
  - ios-arm64-simulator (static, MH_OBJECT, platform IOSSIMULATOR, minos 17.0)
- Gotcha logged: `libtool -static` produces an ar archive which `xcodebuild -create-xcframework` rejects. Must use `ld -r` for relocatable MH_OBJECT output. Sim slice needs `-platform_version ios-simulator` + `--sdk iphonesimulator` to avoid platform-tag collision.
- `find_package(XercesC)` doesn't see the cross-prefix through `CMAKE_PREFIX_PATH` (toolchain pins `FIND_ROOT_PATH_MODE_LIBRARY=ONLY`). Bypassed with explicit `XercesC_LIBRARY` / `XercesC_INCLUDE_DIR` / `XercesC_VERSION`.
- `scripts/plugin_static_shim.hpp` written, ready for Phase 4. 4 lines, redirects `CREATE_SHARED_STAGE` → `CREATE_STATIC_STAGE`.

## 2026-05-24 — Phase 4 blocker noted

Phase 4 (build.sh iOS slices) requires GDAL builder's iOS slices (`gdal.xcframework` + `proj.xcframework`) to exist before PDAL can be configured for iOS. Per user, GDAL iOS work is in progress in parallel. Pausing implementation here until those artifacts land.

## 2026-05-24 — GDAL iOS slices landed

`gdal.xcframework` (3 slices) + `proj.xcframework` (2 iOS slices) shipped from sibling builder, including `verify/ios-sample` consumer harness. Phase 4 unblocked.

## 2026-05-24 — Phase 4: build.sh iOS slices

- `build_ios_slice(sdk)` added. Builds PDAL static, out-of-tree plugin compile with `plugin_static_shim.hpp` force-included, `ld -r` merge to MH_OBJECT framework binary.
- `output/pdalcpp.xcframework` now ships 3 slices:
  - macos-arm64 (dynamic, identical to baseline ✓)
  - ios-arm64 (static MH_OBJECT, IOS minos 17.0, 8.6 MB)
  - ios-arm64-simulator (static MH_OBJECT, IOSSIMULATOR minos 17.0)
- E57 plugin verified statically linked: `__GLOBAL__sub_I_E57Reader.cpp` initializer + `l_registerPlugin<E57Reader>` symbol present in iOS binary.
- Swift checksum: `8d80caac3c2309814870048dd0fabf6dd02166b5539053b033278c2925c25aea`.
- Iteration knobs added: `SKIP_MACOS=1` for fast iOS-only re-runs.

### Phase 4 gotchas / upstream-touch summary (all logged in lessons.md)

1. **PDAL's `PDAL_LIB_TYPE` is hardcoded** (`set("SHARED")` without CACHE in `cmake/libraries.cmake`). `BUILD_SHARED_LIBS=OFF` is silently ignored. Patched in place to STATIC for iOS; restored via trap RETURN.
2. **`install(EXPORT PDALTargets)` fails when STATIC** because vendor static libs (pdal_h3, pdal_arbiter, etc.) aren't in the export set. Surgically commented out via python regex.
3. **`apps/pdal` CLI + `plugins/faux` link fail on iOS** with `CURL::libcurl-NOTFOUND` (malformed Make token) because their imported-target dep resolves empty. Sidestepped by `cmake --build --target pdalcpp` + manual artifact copy. We don't need those binaries anyway.
4. **`dimbuilder` is a build-time codegen executable** PDAL builds and runs. Cross-compiled iOS binary can't run on host. PDAL exposes `DIMBUILDER_EXECUTABLE` cache var for exactly this case — pointed at host-build's binary at `${BUILD_DIR}/bin/dimbuilder`.
5. **Many find_package() consumers need explicit vars** under iOS toolchain because `FIND_ROOT_PATH_MODE_LIBRARY=ONLY` blocks CMAKE_PREFIX_PATH-driven discovery. Set explicitly: TIFF/PROJ/CURL/ZLIB `_LIBRARY` + `_INCLUDE_DIR`, GeoTIFF via stub-header + stub config.
6. **PROJ's `find_dependency(TIFF)`** triggers because PROJ was built with TIFF support but TIFF is merged inside `gdal.xcframework`. Fixed by stubbing FindTIFF's REQUIRED_VARS. Real fix belongs in gdal-builder's `fix-cmake-static.sh`.
7. **CURL headers** needed for compile (Connector.cpp + arbiter), `libcurl.tbd` for link. iOS SDK 26.2 doesn't ship curl headers in `usr/include/curl/`; use Homebrew curl include path.

## 2026-05-24 — Phase 6: verify/ios-sample harness

- `verify/ios-sample/` SwiftPM package with C-ABI bridge over `pdal::StageFactory`. Mirrors gdal-builder's verify pattern.
- Tests pass on iOS Simulator (iPhone 17 Pro):
  - `testLasReaderRegistered` — proves PDAL's core in-tree static-init runs on iOS.
  - `testE57ReaderRegistered` — proves out-of-tree plugin compile + shim-redirected `CREATE_STATIC_STAGE` is wired up.
- Device-target build (`-destination 'generic/platform=iOS'`) succeeds (compile-only; no provisioning for actual on-device run).
- Two issues surfaced + fixed:
  - **`ar -x` collision**: PDAL has duplicate `.o` basenames (`expr/Expression.cpp.o` vs `mongoexpression/Expression.cpp.o`). Switched `build_ios_slice` to `ld -r -force_load <archive>` per .a, no extraction. Lessons logged.
  - **iOS lacks libcurl**: SDK ships no `libcurl.tbd` or headers. Consumer-side `-Wl,-undefined,dynamic_lookup` accepts curl symbols as runtime-resolved; local-file pipelines never hit them.
- Phase 6 acceptance criteria met:
  - SwiftPM Package.swift declares 4 binaryTargets, builds for iOS Simulator + device.
  - Smoke test exercises both core (`readers.las`) and plugin (`readers.e57`) registration.
  - macOS slice regression: diff-frameworks.sh no-op.

## 2026-05-24 — Phase 7: SwiftPDAL iOS integration

- `Package.swift` adds `.iOS("17.0")` platform.
- All xcframeworks switched to `path:` binaryTargets (Frameworks/ mirror) for local iteration.
- `proj` binary target added (iOS-only artifact from gdal-builder).
- `CxxPDAL` target gets iOS-conditional settings:
  - `-I Frameworks/pdalcpp.xcframework/ios-arm64/pdalcpp.framework/Headers` (for `<pdal/...>` includes)
  - Linked libs: z, iconv, xml2, sqlite3, c++ (system)
  - Linked frameworks: Security, CoreFoundation, SystemConfiguration (for libcurl's SecureTransport TLS path)
- `StreamingBench` source wrapped in `#if os(macOS)` — dev-only CLI, not meaningful on iOS.
- 20/23 SwiftPDAL tests pass on iOS Simulator (iPhone 17 Pro, iOS 26.3.1):
  - All LAZ reads, COPC streaming, conversions, cancellation, progress.
  - `convertPlyToLaz`, `convertLazRoundTrip`, `convertReportsProgress`.
  - All streaming LOD/budget/halo/eviction tests.
- 3 failures, all SwiftPDAL-side (not builder concerns):
  - `readE57File` / `streamingReadE57File`: PDAL pipeline adds `filters.reprojection` which errors because `bunnyFloat.e57` has no SRS. Same failure mode on any platform with this input.
  - `streamingSource_wantedSet_stableAcrossTicksWhenViewUnchanged`: cache-hit timing flake, unrelated.

### libcurl cross-build (followup discovered during Phase 7)

Initial Phase 7 attempt with `-Wl,-undefined,dynamic_lookup` for curl crashed
*every* test at startup in `pdal::arbiter::http::Pool::Pool` — PDAL's arbiter
eagerly constructs an HTTP Pool on startup, not lazily, so runtime resolution
of curl symbols was insufficient.

Solution: `scripts/deps/curl.sh` cross-builds libcurl statically for iOS
(SecureTransport TLS, no other protocols/deps) and `build_ios_slice` merges
it into `pdalcpp.framework`'s binary at the `ld -r` step alongside the PDAL
vendor archives. CURL_VERSION pinned to 8.10.1.

Gotcha logged: curl 8.10.1's CMake flag for disabling libidn2 is `USE_LIBIDN2=OFF`,
not `CURL_USE_LIBIDN2=OFF` (the latter is silently treated as uninitialized and
curl auto-detects Homebrew's libidn2 from pkgconfig).
