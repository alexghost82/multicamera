// swift-tools-version: 5.9
import PackageDescription
import Foundation

let ffmpeg = ProcessInfo.processInfo.environment["FFMPEG_PREFIX"] ?? "/opt/homebrew/opt/ffmpeg"

let appInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "CameraWall",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "CameraWall", targets: ["CameraWall"])],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .target(name: "CameraCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "VideoBridge", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + ffmpeg + "/include"])],
                linkerSettings: [
                    .unsafeFlags(["-L" + ffmpeg + "/lib", "-Xlinker", "-rpath", "-Xlinker", ffmpeg + "/lib"]),
                    .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                    .linkedFramework("CoreVideo"), .linkedFramework("VideoToolbox")
                ]),
        .executableTarget(name: "CameraWall", dependencies: [
            "CameraCore", "VideoBridge",
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ], resources: [.copy("Resources/acta-logo.png")],
                          linkerSettings: [
                            // SwiftPM executables need privacy metadata when run outside the app bundle.
                            .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                          "-Xlinker", "__info_plist", "-Xlinker", appInfoPlist])
                          ]),
        .testTarget(name: "CameraCoreTests", dependencies: ["CameraCore", "VideoBridge"]),
        .testTarget(name: "CameraWallTests", dependencies: [
            "CameraWall", "CameraCore", "VideoBridge",
            .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
        ])
    ]
)
