// swift-tools-version: 6.0
//
// Minimal harness proving the iOS slices of pdalcpp.xcframework +
// E57Format.xcframework + gdal.xcframework + proj.xcframework all link
// + load cleanly. Uses a thin C ABI bridge over PDAL's C++ API
// (StageFactory.createStage) so the Swift side stays C-only and we
// don't need full Cxx-interop just for a smoke test.
//
// Build (compile-only on device, full test on simulator):
//   xcodebuild -scheme IOSSample-Package \
//     -destination 'generic/platform=iOS' build
//   xcodebuild -scheme IOSSample-Package \
//     -destination 'platform=iOS Simulator,name=iPhone 16' test

import PackageDescription

let package = Package(
    name: "IOSSample",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "IOSSample", targets: ["IOSSample"]),
    ],
    targets: [
        .binaryTarget(name: "pdalcpp", path: "../../output/pdalcpp.xcframework"),
        .binaryTarget(name: "E57Format", path: "../../output/E57Format.xcframework"),
        .binaryTarget(
            name: "gdal",
            path: "../../../gdal-xcframework-builder/output/gdal.xcframework"
        ),
        .binaryTarget(
            name: "proj",
            path: "../../../gdal-xcframework-builder/output/proj.xcframework"
        ),

        // Thin C ABI over pdal::StageFactory. Header is C-only so the
        // Swift target can `import IOSSampleCxx` without engaging full
        // Cxx interoperability (SwiftPDAL does that — out of scope here).
        .target(
            name: "IOSSampleCxx",
            dependencies: ["pdalcpp", "E57Format", "gdal", "proj"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .define("PDAL_DLL_EXPORT", to: "1"),
                // PDAL's headers nest under `pdal/` inside the framework
                // (`Headers/pdal/StageFactory.hpp`). xcodebuild only adds
                // the framework parent via `-F`; for `<pdal/...>`-style
                // includes to resolve, also add the framework's Headers/
                // dir as a plain user include path. SwiftPDAL macOS users
                // hit the same need.
                .unsafeFlags([
                    "-I",
                    "/Users/mnmly/Development-local/GitHub/cpp/pdal-xcframework-builder/output/pdalcpp.xcframework/ios-arm64/pdalcpp.framework/Headers"
                ]),
            ],
            // System libs PDAL + bundled gdal/proj transitively need.
            // PDAL uses zlib/libxml2/curl; PROJ uses sqlite3; arbiter
            // pulls curl; iconv comes via xerces transcoder.
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("c++"),
                // iOS SDK ships no libcurl. PDAL pulls curl symbols
                // via Connector.cpp + arbiter.cpp; we don't exercise
                // any HTTP I/O path from this verify (local-file
                // readers only). -undefined dynamic_lookup lets the
                // linker accept the unresolved curl symbols as
                // run-time-resolved; they will crash if ever called,
                // which is fine for the verify's read-local-files
                // scope. SwiftPDAL consumers will need to either
                // ship a real libcurl iOS slice or avoid HTTP code.
                .unsafeFlags(["-Wl,-undefined,dynamic_lookup"]),
            ]
        ),

        .target(
            name: "IOSSample",
            dependencies: ["IOSSampleCxx"]
        ),

        .testTarget(
            name: "IOSSampleTests",
            dependencies: ["IOSSample"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
