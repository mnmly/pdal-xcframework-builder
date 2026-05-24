# Lessons

> Append entries as failures are discovered or non-obvious decisions are
> validated. Format: `## YYYY-MM-DD — <short title>`.

---

## 2026-05-24 — Static E57 plugin: use PDAL's existing static-init path, no upstream patch

**Context.** Phase 0 spike for iOS static slices. PDAL's `PDAL_ADD_PLUGIN`
macro (`src/cmake/macros.cmake:139`) hardcodes `add_library(... SHARED ...)`
— `BUILD_SHARED_LIBS=OFF` has no effect. Need a way to ship the E57 reader
inside `libpdalcpp.a` on iOS without patching upstream.

**Findings.**

1. PDAL already ships two registration macros in `src/pdal/PluginHelper.hpp`:
   - `CREATE_SHARED_STAGE(T, info)` — emits `extern "C" PF_initPlugin()`
     for dlopen-style loading. Used by plugin sources today.
   - `CREATE_STATIC_STAGE(T, info)` — emits `static bool T##_b =
     registerPlugin<T>(info);` for static-init self-registration. Used by
     **all in-tree readers** (LasReader, CopcReader, SbetReader, ...) which
     are compiled into `libpdal_base.a` directly.
2. The in-tree pattern proves static-init works for PDAL stage registration
   — same constraints (consumer needs `-force_load` / `-Wl,-all_load` to
   prevent linker from dropping uninstantiated globals) apply equally to
   PDAL's own readers, so this is not a new burden. SwiftPDAL's existing
   static-link arrangement must already handle this for the bundled
   readers.
3. PDAL's E57 plugin `CMakeLists.txt` does `add_subdirectory(libE57Format)`
   — it builds libE57Format inline from PDAL's vendored copy. It does NOT
   `find_package(E57Format)`. So on iOS we can simply
   `-DBUILD_PLUGIN_E57=OFF` at PDAL configure time and PDAL won't try to
   build libE57Format at all.

**Decision: out-of-tree plugin compile with force-included shim.**

For each iOS slice:

1. Configure PDAL with `BUILD_SHARED_LIBS=OFF` + `BUILD_PLUGIN_E57=OFF` →
   produces `libpdalcpp.a` (no plugin).
2. Separately compile the 5 plugin source files via clang++ for the iOS
   target:
   - `src/plugins/e57/io/E57Reader.cpp`
   - `src/plugins/e57/io/E57Writer.cpp`
   - `src/plugins/e57/io/Scan.cpp`
   - `src/plugins/e57/io/Utils.cpp`
   - `src/plugins/e57/io/Uuid.cpp`
3. Force-include a tiny shim header (`scripts/plugin_static_shim.hpp`)
   that redefines `CREATE_SHARED_STAGE` → `CREATE_STATIC_STAGE`:

   ```cpp
   #pragma once
   #include <pdal/PluginHelper.hpp>
   #undef CREATE_SHARED_STAGE
   #define CREATE_SHARED_STAGE(T, info) CREATE_STATIC_STAGE(T, info)
   ```

   Apply via `clang++ -include scripts/plugin_static_shim.hpp ...`. After
   this, the plugin's `CREATE_SHARED_STAGE(E57Reader, s_info)` expands to
   the static-init form, identical to in-tree readers.

4. Archive the resulting `.o` files into `libpdal_plugin_reader_e57.a`,
   then `libtool -static -arch_only arm64 -o pdalcpp libpdalcpp.a
   libpdal_plugin_reader_e57.a` to produce the framework binary.

**Why this beats other options:**

- **Out-of-tree vs. patching `macros.cmake`:** patching the macro to emit
  STATIC still leaves `CREATE_SHARED_STAGE` calls broken — the symbol
  would be dropped at consumer link. We'd need a SECOND patch to
  `PluginHelper.hpp` to redirect. Two patches > one shim.
- **Force-include vs. patching plugin source:** force-include leaves
  `E57Reader.cpp` etc. untouched on disk; the shim lives in our builder
  repo only. Source-tree mutation via sed would have to re-run after every
  upstream tag bump.
- **vs. building libE57Format inline via PDAL's vendored copy:** that
  conflates two concerns (libE57Format binary vs. PDAL plugin code) and
  would duplicate work already done by `build_e57.sh`. Out-of-tree
  compile pulls libE57Format headers + the static archive from our own
  `E57Format.xcframework` iOS slice.

**Open follow-up.** The plugin sources also need xerces-c headers in the
include path if any of them include xerces directly. To verify during
Phase 4 — likely they don't (xerces is libE57Format's internal detail),
but check with `grep -l xercesc src/plugins/e57/io/*.cpp`.

**Open follow-up.** `-force_load` requirement at consumer side — confirm
SwiftPDAL already does this for its in-tree-reader use, or document the
new requirement in README + SwiftPDAL Package.swift change.

---

## 2026-05-24 — diff-frameworks baseline drifts when Homebrew updates

**Symptom.** After refactoring `build.sh` and re-running, `diff-frameworks.sh`
reported a diff in bundled libs: `libproj.25.9.8.0.dylib` → `libproj.25.9.8.1.dylib`.
Refactor was structurally a no-op (function wrap only).

**Cause.** PROJ in Homebrew got a patch bump between baseline capture and
re-run. `dylibbundler` pulls whatever Homebrew currently has, so any
brew-update between baseline and candidate produces a false positive.

**Mitigation.** Treat the baseline as a moving reference: re-capture it
whenever Homebrew updates a bundled dep, before any refactor work that
shouldn't change output. The harness still catches refactor-caused diffs
on the framework binary's own install_name, rpaths, and exported
symbols — which is what matters. Only the `Libraries/*` file list and
its members' metadata are vulnerable to host drift.

**How to apply.** If `diff-frameworks.sh` reports a diff in `Libraries/`
versions only, run `brew list --versions <dep>` to confirm host drift,
then re-baseline. If the diff includes the framework binary's own
metadata, that's a real refactor regression — investigate.

---

## 2026-05-24 — xerces-c samples break iOS configure unless `CMAKE_MACOSX_BUNDLE=OFF`

**Symptom.** Configuring xerces-c 3.3.0 with `CMAKE_SYSTEM_NAME=iOS`
fails at samples/CMakeLists.txt:150 — `install TARGETS given no BUNDLE
DESTINATION for MACOSX_BUNDLE executable target "CreateDOMDocument"`.

**Cause.** xerces-c's top-level CMakeLists.txt does
`add_subdirectory(samples)` unconditionally — no `-Dsamples=OFF` flag
exists. When `CMAKE_SYSTEM_NAME=iOS`, `add_executable` defaults the
`MACOSX_BUNDLE` target property to TRUE, and CMake refuses to `install`
a bundle without a `BUNDLE DESTINATION`.

**Fix.** `-DCMAKE_MACOSX_BUNDLE=OFF` at configure time. This is global,
coerces the sample executables back to plain CLI binaries, install
proceeds normally. Samples still build (a few seconds, harmless) and
land in `${prefix}/bin/`. Library output (`lib/libxerces-c.a`) is what
we care about; the unused sample binaries are ignored downstream.

**How to apply.** Already in `scripts/deps/xerces-c.sh`. If a future
xerces-c version adds a `samples=OFF` option, prefer that and drop the
`CMAKE_MACOSX_BUNDLE` workaround.

**Validation gotcha:** `vtool -show-build` on a static archive (`.a`)
errors with "file is not mach-o" — archives are not Mach-O containers.
To inspect Mach-O headers, extract a member: `ar -x libfoo.a && vtool
-show-build SomeMember.cpp.o`. The script uses `lipo -archs` for the
arm64 check, which works on archives directly.

---

## 2026-05-24 — Static iOS framework binary must be MH_OBJECT, not ar archive

**Symptom.** `xcodebuild -create-xcframework -framework ios.framework`
errors with `unable to find any architecture information in the binary
at '...': Unknown header: 0xb17c0de`.

**Root cause.** Static iOS frameworks expect the framework binary to be
a single relocatable Mach-O object file (MH_OBJECT), not an ar archive.
`libtool -static -o framework_binary lib1.a lib2.a` produces an ar
archive (`!<arch>` magic = `0x213c6172`), which `xcodebuild` rejects.

The `0xb17c0de` magic is what xcodebuild sees when it walks into the ar
archive looking for Mach-O headers and hits LLVM bitcode-shaped bytes
inside one of the member headers — misleading error, but the underlying
issue is the archive format itself.

**Fix.** Extract all `.o` from each input archive into a temp dir, then
relocatably link them with `ld -r`:

```bash
mkdir -p objdir && cd objdir
ar -x /path/to/lib1.a
ar -x /path/to/lib2.a
ld -r -arch arm64 \
    -syslibroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -platform_version ios 17.0 17.0 \
    -o framework_binary \
    objdir/*.o
```

This produces a single Mach-O `MH_OBJECT` file with `LC_BUILD_VERSION`
pointing at iOS, `lipo -info` reports arm64, `file` says "Mach-O 64-bit
object arm64". `xcodebuild -create-xcframework` accepts it.

**How to apply.** Already in `build_e57.sh build_ios_slice`. The same
approach will be needed in `build.sh build_ios_slice` for the merged
`libpdalcpp.a + libpdal_plugin_reader_e57.a` framework binary.

**Disambiguation for sim slice.** Use
`-platform_version ios-simulator 17.0 17.0` and
`-syslibroot $(xcrun --sdk iphonesimulator --show-sdk-path)` for the
simulator. Otherwise `LC_BUILD_VERSION` reports IOS for both slices and
xcodebuild rejects the second as a duplicate.

**Caveat: xcodebuild also accepts ar archives** for the framework
binary in some Xcode versions — the sibling gdal-xcframework-builder
ships ar-archive iOS slices and xcframework creation succeeds. The
"Unknown header: 0xb17c0de" failure we hit on E57Format may have been
caused by a specific archive structure (libtool symbol table layout?),
not the ar format itself. `ld -r` MH_OBJECT works in both cases and is
the safer default.

---

## 2026-05-24 — PDAL iOS: minimum upstream patches required

PDAL 2.10.1 is not iOS-cross-compile-clean out of the box. Three small
patches applied at configure time, all wrapped in `.ios-static.bak`
restoration so the macOS slice (which re-runs CMake on each build) is
unaffected.

### Patch 1: `cmake/libraries.cmake` — STATIC override

`set(PDAL_LIB_TYPE "SHARED")` (no CACHE). `BUILD_SHARED_LIBS=OFF` and
`-DPDAL_LIB_TYPE=STATIC` both get clobbered when this file is
included. Sed-patch the literal string from "SHARED" to "STATIC".

### Patch 2: `CMakeLists.txt` — disable install(EXPORT PDALTargets)

When STATIC, `install(EXPORT)` fails with `target "pdalcpp" requires
target "pdal_h3" that is not in any export set` (and many more — every
vendor static lib). Fix would be wiring all vendor libs into the export
set, but we don't ship PDAL's cmake config downstream — consumers use
SwiftPDAL's framework module map. Python regex removes the
`export(TARGETS …)` + `install(EXPORT PDALTargets …)` blocks.

### Why no patches to plugin/macros.cmake (the `SHARED` hardcode)

PDAL's `PDAL_ADD_PLUGIN` macro hardcodes `add_library(... SHARED ...)`
(`cmake/macros.cmake:139`). We sidestep by passing
`-DBUILD_PLUGIN_E57=OFF` and compiling the plugin sources out-of-tree
with `scripts/plugin_static_shim.hpp` force-included. Zero source
patches to the plugin code. See "Static E57 plugin" entry above.

### Build-target restriction

We `cmake --build --target pdalcpp` instead of the all-target default.
This avoids two downstream targets that won't link cleanly under
STATIC: `apps/pdal` (the CLI) and `plugins/faux` — both fail with
`CURL::libcurl-NOTFOUND` as a literal Make dependency token. The
underlying cause is FindCURL's IMPORTED_LOCATION not being set when
`CURL_LIBRARY` points at an iOS-SDK `.tbd` text-stub (the `EXISTS`
check in FindCURL.cmake behaves oddly under iOS toolchain). We don't
need either binary; `cmake --install` is skipped and headers + the
static archive are manually staged.

### Other configure quirks

- `DIMBUILDER_EXECUTABLE`: PDAL's `cmake/dimension.cmake` has explicit
  cross-compile support. Point at host-built dimbuilder under
  `${BUILD_DIR}/bin/dimbuilder` (built by build_macos_slice).
- TIFF/PROJ/CURL/ZLIB/GEOTIFF need explicit `_LIBRARY` + `_INCLUDE_DIR`
  vars because the iOS toolchain blocks discovery via
  `CMAKE_PREFIX_PATH`. TIFF + GeoTIFF symbols are merged into
  `gdal.xcframework`; we pass non-existent stub paths that satisfy
  find_package's REQUIRED_VARS check without actually being linked.
- GeoTIFF additionally needs a stub `geotiff.h` (under
  `scripts/stubs/include/`) with `#define LIBGEOTIFF_VERSION 1700` so
  PDAL's `cmake/modules/FindGeoTIFF.cmake` version parse succeeds.
- iOS SDK 26.2 doesn't ship `usr/include/curl/` headers. Use Homebrew
  `$(brew --prefix curl)/include` for compile; link still uses SDK's
  `usr/lib/libcurl.tbd`.
- `CMAKE_MACOSX_BUNDLE=OFF` needed because `add_executable` on iOS
  defaults `MACOSX_BUNDLE` to TRUE; install() then demands BUNDLE
  DESTINATION which PDAL's apps/CMakeLists doesn't supply.

---

## 2026-05-24 — Use `ld -r -force_load <archive>` not `ar -x`; PDAL has duplicate `.o` basenames

**Symptom.** Test bundle dlopen on iOS Simulator failed:
`dlopen ...: symbol not found in flat namespace
'__ZNK4pdal4expr10Expression5printEv'`. Linker phase passed but runtime
load couldn't resolve a symbol that should have been in the framework
binary.

**Cause.** Initial `build_ios_slice` extracted archive members with
`ar -x libpdalcpp.a` then `ld -r objs/*.o`. PDAL has two `.o` files
with the same basename:
- `filters/private/expr/Expression.cpp.o` (defines `pdal::expr::Expression::print`)
- `filters/private/mongoexpression/Expression.cpp.o`

`ar -x` extracts members to the current directory using their stored
filename. When two members share a name, the second overwrites the
first silently. The `pdal::expr::Expression::print` definition was
lost; references inside the framework binary remained `U` (undefined),
which the linker accepts (it sees the references will be resolved
internally) but the dlopen-time symbol bind fails.

**Fix.** Stop using `ar -x` for the merge. Use `ld -r -force_load <a>`
on each archive instead — `ld` extracts members by internal index, so
filename collisions are irrelevant. `-force_load` also guarantees ALL
members get included, which keeps static-init globals (E57Reader
registrar, etc.) alive even if no symbol from those files is referenced.

```bash
ld -r -arch arm64 \
    -syslibroot "${sdk_root}" \
    -platform_version ios 17.0 17.0 \
    -o framework_binary \
    -force_load libpdalcpp.a \
    -force_load libpdal_lazperf.a \
    ... (each vendor archive)
```

**How to apply.** Already in `build_ios_slice`. The earlier `ar -x`
approach in `build_e57.sh` is fine for that builder because xerces +
libE57Format don't have duplicate basenames — but switching it to
`ld -r -force_load` would be a defensive improvement.

---

## 2026-05-24 — Framework headers under nested `pdal/` subdir need explicit `-I` for consumers

**Symptom.** SwiftPM consumer using `.binaryTarget(path: "pdalcpp.xcframework")`
fails to compile a C++ source that includes `<pdal/StageFactory.hpp>`
with `'pdal/StageFactory.hpp' file not found`.

**Cause.** Framework convention is `<FrameworkName>/Header.h` resolving
to `FrameworkName.framework/Headers/Header.h`. xcodebuild only adds
`-F <parent>` to the consumer link, exposing
`<pdalcpp/Something.h>` style includes. PDAL's headers live under
`Headers/pdal/...` (deliberate — matches the source tree's
`<pdal/...>` convention preserved across the entire downstream
ecosystem), so `<pdal/StageFactory.hpp>` doesn't resolve without an
explicit `-I framework/Headers` flag.

**Fix in `verify/ios-sample/Package.swift`.** Added an absolute-path
`.unsafeFlags(["-I", ".../Headers"])` to the C++ wrapper target's
cxxSettings. Brittle (hardcoded path), but acceptable for a local
verify harness. SwiftPDAL macOS works the same way; presumably needs
the same treatment for iOS — flag for Phase 7 follow-up.

**Alternative not chosen:** flatten `Headers/pdal/*` into `Headers/`
at framework root. Would break the source-level `#include <pdal/...>`
convention every PDAL consumer expects.

**Note on module map.** The shipped `resources/module.modulemap`'s
`umbrella header "pdal.hpp"` references it as if it were at
`Headers/pdal.hpp`, but the actual file is at `Headers/pdal/pdal.hpp`.
This appears to be tolerated by clang — the macOS slice has the same
mismatch and SwiftPDAL builds fine. Worth fixing eventually with
`umbrella header "pdal/pdal.hpp"` plus per-submodule path prefixes,
but not blocking.

---

## 2026-05-24 — iOS SDK has no libcurl; use `-Wl,-undefined,dynamic_lookup` for pipelines that don't need HTTP I/O

**Symptom.** Consumer link fails with `ld: library 'curl' not found`.
Neither `iPhoneOS26.2.sdk/usr/lib/libcurl.*` nor
`iPhoneSimulator26.2.sdk/usr/lib/libcurl.*` exist.

**Context.** iOS apps are expected to use NSURLSession / CFNetwork
for HTTP, not libcurl. PDAL's `Connector` (used by EPT/COPC remote
readers) and `arbiter` (used pervasively for I/O abstraction) both
include `<curl/curl.h>` unconditionally. Symbols land in the framework
binary even when the consumer never uses HTTP I/O.

**Fix at consumer side (verify/ios-sample).** Add
`-Wl,-undefined,dynamic_lookup` to the consumer's linker settings.
Unresolved curl symbols become weak-style runtime references that
crash only if actually called. For local-file pipelines (LAS, E57,
COPC local) the curl path is never hit.

**Real-world implication.** SwiftPDAL consumers will need the same
treatment OR ship a cross-built libcurl iOS slice (curl builds for
iOS without too much pain — autoconf + iOS toolchain). Document as
a follow-up: if any SwiftPDAL pipeline uses EPT/COPC-remote, libcurl
must actually be available on iOS at runtime.

**Updated 2026-05-24.** `-Wl,-undefined,dynamic_lookup` does NOT work
for PDAL on iOS. PDAL's `arbiter::http::Pool::Pool` is constructed
*eagerly on startup* (not lazily), so curl symbols are dereferenced
before any local-file pipeline runs. Every test crashed at the same
constructor. Real fix: cross-build libcurl statically. See next entry.

---

## 2026-05-24 — Cross-built libcurl for iOS (scripts/deps/curl.sh)

**Decision.** Cross-build a minimal libcurl for iOS, merge into
`pdalcpp.framework`'s binary alongside PDAL vendor archives. Curl's
CMake build is well-behaved; iOS only needs HTTPS via SecureTransport.

**Script** (`scripts/deps/curl.sh`) mirrors `scripts/deps/xerces-c.sh`:
- Shallow clone curl at `CURL_VERSION` (default 8.10.1).
- CMake configure with iOS toolchain, `BUILD_SHARED_LIBS=OFF`,
  SecureTransport for TLS, everything else off.
- `lipo -archs` validation, idempotent skip if archive present.

**Disabled protocols/deps** (keeps the archive small and dep-free):
LDAP, RTSP, DICT, FILE, FTP, GOPHER, IMAP, POP3, SMB, SMTP, TELNET,
TFTP, MQTT, OpenSSL, MbedTLS, WolfSSL, libssh, libssh2, libpsl,
libidn2, brotli, zstd. Just HTTP/HTTPS over SecureTransport.

**Gotcha: curl's option naming.** The flag to disable libidn2 is
`USE_LIBIDN2=OFF` (no `CURL_` prefix). `CURL_USE_LIBIDN2=OFF` is
silently treated as uninitialized and curl auto-detects Homebrew's
libidn2 via pkgconfig — resulting `libcurl.a` references
`idn2_check_version`, `idn2_lookup_ul`, etc., which break consumer link.
Verify with `nm libcurl.a | grep idn2 | head` after build.

**Consumer side (SwiftPDAL).** Removed
`-Wl,-undefined,dynamic_lookup` and `linkedLibrary("curl")`. Added
`linkedFramework("Security"|"CoreFoundation"|"SystemConfiguration")`
for SecureTransport's runtime dependencies on iOS.

**Outcome.** 20/23 SwiftPDAL tests pass on iOS Simulator. Remaining
3 failures are unrelated (E57 file has no SRS for reprojection
filter; cache-hit timing flake).

---

## 2026-05-24 — Framework→library xcframework split for iOS

**Symptom.** iOS app embed corrupts MH_OBJECT framework binaries —
Xcode's pipeline silently strips an 8.6 MB framework binary down to
~50 KB at embed time, and `installd` rejects the .app with
`MIInstallerErrorDomain Code 35 PackageInspectionFailed` /
"had none of the keys that we expect" (misleading; the keys are
present — the binary itself is the problem).

We also tried ar-archive framework binaries — `xcodebuild
-create-xcframework -framework` rejects with "Unknown header:
0xb17c0de" because the framework binary needs to be a Mach-O, not
an ar archive.

**Fix.** Drop the framework wrapper for iOS slices entirely. Ship
each iOS slice as a library xcframework (`<slice>/lib<name>.a` +
optional `<slice>/Headers/`). `xcodebuild -create-xcframework -library`
accepts ar archives natively; Xcode auto-links `.a` files via
`-L <path> -l<name>` and the static symbols land in the consumer's
binary directly. No `.framework` to embed, nothing for `installd`
to validate.

**Constraint.** `xcodebuild` rejects mixing framework + library
slices in one xcframework. So each builder now produces TWO
artifacts:
- `pdalcpp.xcframework` (macOS framework slice only)
- `pdalcpp-ios.xcframework` (iOS device + simulator library slices)
- Same for E57Format.

Consumer Package.swift declares both as `.binaryTarget` with
platform-conditional dependencies.

---

## 2026-05-24 — libtool -static over ld -r for library xcframeworks

`xcodebuild -create-xcframework -library <file>` requires the input
to be a static archive (`.a`). `ld -r` produces a single MH_OBJECT
Mach-O — not an archive, rejected. Use `libtool -static -arch_only arm64`
instead. PDAL's duplicate `.o` basenames (`Expression.cpp.o` in two
filter subdirs) are handled correctly by libtool — ar archives
address members by index, not name.

---

## 2026-05-24 — libE57Format thin-LTO produces bitcode `.o` files

**Symptom.** `xcodebuild -create-xcframework -library libE57Format.a`
rejects with "Unknown header: 0xb17c0de" — LLVM bitcode magic.

**Cause.** libE57Format's CMakeLists enables thin-LTO in Release
builds via `option(E57_RELEASE_LTO ON)`. With LTO on, clang emits
LLVM bitcode `.o` files instead of native Mach-O. xcframework
creation rejects bitcode archives.

**Fix.** Pass `-DE57_RELEASE_LTO=OFF` in `build_e57.sh`'s iOS
configure. Already in place. Note: this disables LTO; minor perf
hit vs. native Mach-O `.o` files, acceptable.

---

## 2026-05-24 — Static-plugin registrar force_load on consumer side

PDAL's plugin registrars are file-scope statics
(`static bool LasReader_b = registerPlugin(...)`). With a static
archive, ld only pulls members that are directly referenced.
Registrars in unreferenced `.o` files get dropped, and
`StageFactory::createStage("readers.las")` returns null at runtime.

`-Wl,-force_load,<archive>` on the consumer side keeps the
registrars alive. Per-archive `-force_load` (not blanket `-all_load`)
because SwiftPDAL also depends on `copclib.xcframework` which bundles
its own lazperf — `-all_load` would pull both copies of lazperf and
fail with duplicate-symbol errors.

**Consumer-side complication.** SwiftPM `.unsafeFlags` rejects Xcode
build variables like `$(BUILT_PRODUCTS_DIR)`. The flag has to live in
the app target's Xcode build settings:

```
OTHER_LDFLAGS[sdk=iphoneos*]        = -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libpdalcpp.a
OTHER_LDFLAGS[sdk=iphonesimulator*] = -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libpdalcpp.a
```

Documented in `CLAUDE.md` "Consumer-side requirements". SwiftPDAL's
`Examples/PDALApp/PDALApp.xcodeproj` is the canonical example.

---

## 2026-05-24 — macOS E57 plugin needs second rpath for libE57Format

The vendored E57 plugin (`libpdal_plugin_reader_e57.dylib`) links
against `@rpath/libE57Format.3.dylib`. The default
`@loader_path/../../..` rpath added in `build.sh` phase 4 only
resolves up to `pdalcpp.framework/`, not the sibling
`E57Format.framework/`.

E57Format.framework is at `Contents/Frameworks/E57Format.framework/`,
sibling to `pdalcpp.framework/`. From the plugin at
`pdalcpp.framework/Versions/A/PlugIns/`, that's 4 `../` hops:
PlugIns → Versions/A → Versions → pdalcpp.framework → Frameworks/.

Add a second rpath in the plugin processing loop:

```
install_name_tool -add_rpath \
    "@loader_path/../../../../E57Format.framework/Versions/A" \
    "$plug"
```

Plugins that don't reference libE57Format ignore the extra rpath
harmlessly.

---

## 2026-05-24 — iOS bundle resource layout differs from macOS

SwiftPDAL's `getPaths(isTesting: false)` was hardcoded to
`Bundle.module.bundleURL.appendingPathComponent("Contents/Resources")`
— macOS framework-bundle convention. On iOS, SwiftPM resource bundles
are flat: resources sit directly under the `.bundle` root, no
`Contents/Resources/` subdirectory.

Fix in `Sources/SwiftPDAL/SwiftPDAL.swift`:

```swift
#if os(iOS)
let projDBURL = Bundle.module.bundleURL.path()
let driversURL = ""  // no loadable plugins on iOS
#else
let projDBURL = Bundle.module.bundleURL.appendingPathComponent("Contents/Resources").path()
let driversURL = ...
#endif
```

iOS also has no plugin dir (pdalcpp is statically linked), so we pass
an empty `driversURL` to disable PDAL's plugin-discovery scan.

---

## 2026-05-24 — Reprojection requires source SRS (PLY/E57 fix)

`filters.reprojection` errors out at `prepare()` with "source data has
no spatial reference and none is specified with the 'in_srs' option"
when the source file lacks an SRS. Common for E57 and PLY files which
typically use local coordinates.

**Fix in SwiftPDAL's pdal_wrapper.cpp.** Probe the source's
`getSpatialReference()` in a throwaway PointTable before deciding
whether to add `filters.reprojection`. Skip the filter when the
source has no SRS or when probing throws. Files with proper SRS still
get reprojected; files without don't crash.
