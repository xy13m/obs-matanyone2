// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "obs-matanyone2",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MatAnyone2Core", targets: ["MatAnyone2Core"]),
        // The dylib name must differ from the reference plugin's
        // libMatAnyone2Bridge.dylib: dyld resolves @rpath by install name across
        // all loaded OBS modules, so a duplicate name would shadow the other copy.
        .library(
            name: "MatAnyone2MattingBridge", type: .dynamic, targets: ["MatAnyone2Bridge"]),
        .executable(name: "matanyone2-benchmark", targets: ["MatAnyone2Benchmark"]),
    ],
    dependencies: [
        // Fork of github.com/flowtyone/MatAnyone2Kit. Pinned by revision; bump it
        // whenever the fork gains a commit the plugin needs.
        .package(
            url: "https://github.com/xy13m/MatAnyone2Kit",
            revision: "accb1bd4b6bbd768923a6a58482be9fb47446a68"
        )
    ],
    targets: [
        // OBS-free logic: mask math, calibration, manifest parsing. Unit tested.
        .target(name: "MatAnyone2Core"),
        // Catches NSException raised inside Core ML so a failed prediction does
        // not take OBS down.
        .target(name: "ObjCExceptionCatcher", publicHeadersPath: "include"),
        // Worker thread, Core ML engine, Vision seeding, calibration and
        // persistence. Shared by the plugin bridge and the benchmark.
        .target(
            name: "MatAnyone2Pipeline",
            dependencies: [
                .product(name: "MatAnyoneKitCoreML", package: "MatAnyone2Kit"),
                "MatAnyone2Core",
                "ObjCExceptionCatcher",
            ]
        ),
        // C ABI over the pipeline, built as a dylib and linked by the C++ module.
        // The C header lives in Sources/MatAnyone2Bridge/include and is added to
        // the clang++ include path by scripts/build-plugin.sh.
        .target(name: "MatAnyone2Bridge", dependencies: ["MatAnyone2Pipeline"]),
        .executableTarget(name: "MatAnyone2Benchmark", dependencies: ["MatAnyone2Pipeline"]),
        .testTarget(name: "MatAnyone2CoreTests", dependencies: ["MatAnyone2Core"]),
        .testTarget(name: "MatAnyone2PipelineTests", dependencies: ["MatAnyone2Pipeline"]),
    ],
    swiftLanguageModes: [.v6]
)
