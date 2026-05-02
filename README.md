# pdal-xcframework-builder

Standalone builder that produces `pdalcpp.xcframework` for macOS (arm64) from any tagged PDAL release. Mirrors `gdal-xcframework-builder` — keeps the recipe outside the PDAL source tree.

## Prerequisites

- A built `gdal.xcframework` (e.g. produced by `gdal-xcframework-builder`)
- Homebrew packages: `cmake dylibbundler proj@9 expat xerces-c`

## One-time setup

```sh
cp config.sh.example config.sh
$EDITOR config.sh   # set GDAL_XCFRAMEWORK and (optional) CODESIGN_IDENTITY, OUTPUT_DIR
```

## Build

```sh
make PDAL_VERSION=2.10.1
```

Or directly:

```sh
./build.sh 2.10.1
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
