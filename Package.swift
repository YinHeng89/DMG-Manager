// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DMGLibrary",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DMGLibrary", targets: ["DMGLibrary"])
    ],
    targets: [
        // macOS 自带 libsqlite3，通过 system library 直接链接，零外部依赖
        .systemLibrary(name: "CSQLite"),
        .executableTarget(
            name: "DMGLibrary",
            dependencies: ["CSQLite"],
            path: "Sources/DMGLibrary"
        ),
        .testTarget(
            name: "DMGLibraryTests",
            dependencies: ["DMGLibrary"],
            path: "Tests/DMGLibraryTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
