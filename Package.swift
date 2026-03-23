// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "FileForge",
  platforms: [
    .macOS(.v12)  // Monterey
  ],
  products: [
    .executable(
      name: "FileForge",
      targets: ["FileForge"]
    ),
    .library(
      name: "FileForgeCore",
      targets: ["FileForge"]
    )
  ],
  targets: [
    .executableTarget(
      name: "FileForge",
      dependencies: []
    ),
    .testTarget(
      name: "FileForgeTests",
      dependencies: ["FileForge"]
    )
  ]
)
