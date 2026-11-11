// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PrecisionEraserCore",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "eraser-test-runner", targets: ["PrecisionEraserCore"])
    ],
    targets: [
        .executableTarget(
            name: "PrecisionEraserCore",
            path: "Sources"
        )
    ]
)
