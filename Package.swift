// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Forge",
  platforms: [
    .macOS(.v13)  // Ventura
  ],
  products: [
    .executable(
      name: "Forge",
      targets: ["Forge"]
    )
  ],
  targets: [
    .executableTarget(
      name: "Forge",
      dependencies: []
    ),
    .testTarget(
      name: "ForgeTests",
      dependencies: ["Forge"]
    )
  ]
)
