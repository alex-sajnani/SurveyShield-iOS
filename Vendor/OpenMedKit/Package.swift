// swift-tools-version: 5.9
// Vendored from https://github.com/maziyarpanahi/openmed (swift/OpenMedKit, v1.7.0).
// Vendored because the repo's root manifest omits the `resources:` declaration,
// which breaks Bundle.module. Remove this copy and switch back to the remote
// package once upstream ships a fix.

import PackageDescription

let package = Package(
    name: "OpenMedKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OpenMedKit",
            targets: ["OpenMedKit"]
        )
    ],
    dependencies: [
        // swift-transformers for HuggingFace-compatible tokenization
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.12"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "OpenMedKit",
            dependencies: [
                .product(name: "Transformers", package: "swift-transformers"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "OpenMedKitTests",
            dependencies: ["OpenMedKit"]
        ),
    ]
)
