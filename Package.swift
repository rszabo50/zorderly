// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZOrderly",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "zorderly", targets: ["ZOrderly"])],
    targets: [.executableTarget(name: "ZOrderly")],
    swiftLanguageModes: [.v5]
)
