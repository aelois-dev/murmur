// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .executable(name: "murmur-eval", targets: ["MurmurEval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(name: "MurmurCore"),
        .target(
            name: "MurmurEngine",
            dependencies: [
                "MurmurCore",
                "llama",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore", "MurmurEngine"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "MurmurEval", dependencies: ["MurmurCore", "MurmurEngine"]),
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
