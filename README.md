# pdal-xcframework-builder

Standalone builder that produces four xcframeworks for **macOS arm64 (dynamic) + iOS arm64 device/simulator (static)** from any tagged upstream PDAL release. Mirrors `gdal-xcframework-builder` — keeps the recipe outside the PDAL source tree.

When `BUILD_IOS=1`:

| Artifact | Slices | Shape |
| --- | --- | --- |
| `pdalcpp.xcframework` | macOS arm64 | dynamic `.framework` with dylibbundler'd deps |
| `pdalcpp-ios.xcframework` | ios-arm64 + ios-arm64-simulator | library xcframework (`.a` + `Headers/`) |
| `E57Format.xcframework` | macOS arm64 | dynamic `.framework` with xerces-c bundled |
| `E57Format-ios.xcframework` | ios-arm64 + ios-arm64-simulator | library xcframework |

xcodebuild rejects mixing framework + library slices in one xcframework, hence the `-ios.xcframework` siblings. See `CLAUDE.md`'s "iOS pipeline" section for the why.

## Prerequisites

- A built `gdal.xcframework` (produced by `gdal-xcframework-builder`)
- For iOS slices: `proj.xcframework` (also produced by `gdal-xcframework-builder`)
- Homebrew packages: `cmake dylibbundler proj@9 expat xerces-c curl` (curl for the iOS slice's headers and `find_package(CURL)`)
- Xcode command line tools (`xcodebuild`, `xcrun`)

## One-time setup

```sh
cp config.sh.example config.sh
$EDITOR config.sh   # set GDAL_XCFRAMEWORK, PROJ_XCFRAMEWORK (for iOS), CODESIGN_IDENTITY (optional)
```

## Build

```sh
# macOS-only (current default)
make PDAL_VERSION=2.10.1

# macOS + iOS device + iOS simulator (3-slice xcframework)
BUILD_IOS=1 make PDAL_VERSION=2.10.1

# E57Format builder follows the same pattern
BUILD_IOS=1 make LIBE57_VERSION=3.3.0 e57-xcframework
```

For fast iOS-only iteration during development:

```sh
SKIP_MACOS=1 BUILD_IOS=1 ./build.sh 2.10.1
```

Steps (8 phases):

1. Shallow-clone `https://github.com/PDAL/PDAL` at the given tag into `work/pdal-$PDAL_VERSION/src`
2. Configure with standard install layout (links against the supplied GDAL xcframework + Homebrew proj)
3. `cmake --build` + `cmake --install` into `work/pdal-$PDAL_VERSION/install` (regular dylib + headers, no framework)
4. **Assemble framework structure** at `work/.../stage/pdalcpp.framework`:
   - `Versions/A/pdalcpp` (dylib renamed) with corrected install_name
   - `Versions/A/Headers/pdal/...` (from `install/include/pdal`)
   - `Versions/A/Modules/module.modulemap` (shipped in `resources/`)
   - `Versions/A/Libraries/` (placeholder; populated in phase 5)
   - `Versions/A/PlugIns/...` (plugins relinked to point at the framework binary)
   - `Versions/A/Resources/proj.db` and a fresh `Info.plist` (no smart-quote bugs)
   - `libpdalcpp.<sov>.dylib` symlink so plugins still resolve their old soname
5. `dylibbundler` captures all transitive deps into `Versions/A/Libraries/`, then rpath fixup loop normalises sibling references
6. Top-level framework symlinks (`pdalcpp`, `Headers`, `Modules`, `Libraries`, `Resources`, `PlugIns` → `Versions/Current/...`) and `Versions/Current → A`
7. **Codesign inside-out** — every nested `*.dylib` and the `pdalcpp` Mach-O binary are signed individually first, then the bundle is sealed with `--deep`. Defaults to ad-hoc (`-`) when `CODESIGN_IDENTITY` is unset. macOS 26 rejects pages whose nested-library signatures don't match the outer bundle's resource hashes, so the order matters — do not replace this with a single `--deep` pass.
8. `xcodebuild -create-xcframework` → `OUTPUT_DIR/pdalcpp.xcframework` + `ditto` zip + checksum; (optional) mirror to `SWIFT_PACKAGE_FRAMEWORKS_DIR`

## iOS pipeline

When `BUILD_IOS=1`, the macOS phases above run unchanged, then a sibling `build_ios_slice <device|simulator>` runs for each iOS slice:

1. **Cross-build libcurl + xerces-c statically** for the slice via `scripts/deps/{curl,xerces-c}.sh` into `work/deps-cache/ios-<sdk>/`. SecureTransport TLS for curl (no OpenSSL/MbedTLS), iconv transcoder for xerces (no ICU).
2. **Configure PDAL** against the iOS toolchain (`scripts/toolchain/ios-{device,sim}.cmake`), pointing at:
   - `gdal.xcframework`'s iOS slice for GDAL (CMake config mode via `GDAL_DIR`)
   - `proj.xcframework`'s iOS slice for PROJ
   - The cross-built libcurl + xerces prefixes
   - `DIMBUILDER_EXECUTABLE` pointing at the macOS-host build's dimbuilder (PDAL has explicit cross-compile support for this codegen tool)
3. **Three small CMake patches** applied at configure time and restored on function exit via `trap RETURN`:
   - `cmake/libraries.cmake`: `PDAL_LIB_TYPE "SHARED"` → `"STATIC"` (PDAL doesn't honor `BUILD_SHARED_LIBS=OFF`)
   - `CMakeLists.txt`: comment out `install(EXPORT PDALTargets)` (vendor static libs aren't in the export set; we don't ship PDAL's cmake config downstream)
4. **Build only the `pdalcpp` target** (`cmake --build --target pdalcpp`). The `pdal` CLI and `faux` plugin link via a malformed `CURL::libcurl-NOTFOUND` Make token under STATIC; we don't need either binary.
5. **Out-of-tree E57 plugin compile.** `BUILD_PLUGIN_E57=OFF` in the PDAL configure (its `PDAL_ADD_PLUGIN` macro hardcodes `add_library(SHARED)`). Instead, compile the 5 plugin sources directly with `clang++ -include scripts/plugin_static_shim.hpp`. The shim redirects `CREATE_SHARED_STAGE` → `CREATE_STATIC_STAGE` so the reader registers via static-init (same path PDAL's in-tree readers use), no upstream patch.
6. **`ld -r` merge** of `libpdalcpp.a` + every PDAL vendor static archive (lazperf, kazhdan, h3, arbiter, lepcc, json_schema) + cross-built `libcurl.a` + the 5 plugin `.o` files into a single MH_OBJECT Mach-O framework binary. `-force_load` on each archive ensures static-init globals (E57Reader registrar) are preserved.
   *Why `ld -r` not `libtool -static`*: PDAL has duplicate `.o` basenames (`filters/private/expr/Expression.cpp.o` vs `filters/private/mongoexpression/Expression.cpp.o`). `ar -x` would silently overwrite one with the other.
7. **Assemble flat framework** at `work/.../stage-ios-<slice>/pdalcpp.framework/` — no `Versions/A` symlink dance on iOS:
   - `pdalcpp` (the MH_OBJECT binary)
   - `Headers/pdal/...`, `Modules/module.modulemap`, `Resources/proj.db`, `Info.plist` (with `MinimumOSVersion=17.0`, `CFBundleSupportedPlatforms=[iPhoneOS|iPhoneSimulator]`)
8. **Single `xcodebuild -create-xcframework`** at the top level aggregates the macOS slice + both iOS slices. Same for `build_e57.sh`.

### Consumer-side notes

iOS consumers link the library xcframeworks statically. Two things are needed in the consumer's Xcode project (not Package.swift — SwiftPM's `.unsafeFlags` rejects Xcode variables):

```
OTHER_LDFLAGS[sdk=iphoneos*]        = -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libpdalcpp.a
OTHER_LDFLAGS[sdk=iphonesimulator*] = -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libpdalcpp.a
```

Without `force_load`, PDAL's file-scope plugin registrars get dropped by ld and `StageFactory::createStage("readers.las")` returns null at runtime. Per-archive (not blanket `-all_load`) — copclib.xcframework also bundles lazperf and `-all_load` would duplicate-symbol-error.

Also link:
- System libs: `z`, `iconv`, `xml2`, `sqlite3`, `c++`
- Apple frameworks: `Security`, `CoreFoundation`, `SystemConfiguration` (libcurl's SecureTransport TLS runtime deps)

macOS consumers just link `-framework pdalcpp -framework E57Format`. No force_load, no extra system libs (they're in the dynamic framework's `Libraries/`).

See SwiftPDAL's `Package.swift` and `Examples/PDALApp/` for working consumer examples on all three Apple platforms (macOS, iOS Simulator, iOS device).

### Verify harness

`verify/ios-sample/` is a minimal SwiftPM package that imports the iOS slices and exercises both core (`readers.las`) and plugin (`readers.e57`) registration via `pdal::StageFactory::createStage`. Run with:

```sh
cd verify/ios-sample
xcodebuild -scheme IOSSample -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Other targets

```sh
make PDAL_VERSION=2.10.1 release   # also gh release create
make clean                         # wipe work/
make distclean                     # wipe work/ and output/
```

## Notes

- PDAL tag format varies. The script tries `<version>` first then falls back to `v<version>`. Override with `PDAL_TAG=...` if needed.
- `proj.db` is copied from `${PROJ_PREFIX}/share/proj/proj.db` (default Homebrew location).
- The bundled `module.modulemap` lives in `resources/module.modulemap`. Edit it there to change Swift import surface.
- The script generates a fresh `Info.plist` from scratch — fixes the smart-quote bug (`"“2.10.1”"`) in the prior recipe.
- `Headers/pdal/` is nested under a `pdal/` subdir (matching the existing layout). The umbrella header in `module.modulemap` is `pdal.hpp`. If Swift import paths feel off, this is where to look.
- If `dylibbundler` ever prompts for a missing `@rpath/libfoo.dylib`, `brew install foo` and add its lib dir to `DYLIBBUNDLER_SEARCH_PATHS` in `config.sh`.

## Codesigning

`CODESIGN_IDENTITY` defaults to `-` (ad-hoc) when unset.

**Ad-hoc is fine when:**
- Consumers integrate via SwiftPM and re-sign with their own identity at app-build time.
- Distributing to TestFlight / App Store — Xcode re-signs everything during archive.
- Local development.

**Ad-hoc is NOT enough when:**
- Shipping a notarized `.app`/`.pkg` directly to end users (notarization requires Developer ID + hardened runtime + a real timestamp).
- The consuming app uses hardened runtime with library validation enabled (no `com.apple.security.cs.disable-library-validation` entitlement). Library validation requires nested code signed with the same Team ID as the host.

For Developer ID releases, set:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

and update step 7 of `build.sh` to pass `--timestamp` (instead of `--timestamp=none`) and `--options=runtime` to enable hardened runtime, then notarize the resulting `.zip` with `xcrun notarytool submit`.
