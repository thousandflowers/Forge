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
  dependencies: [
    // Apple's own parser. It generates the help and the shell completions,
    // which is most of what a CLI needs, and it is a compile-time dependency:
    // nothing extra to install to run Forge.
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
  ],
  targets: [
    .executableTarget(
      name: "Forge",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "ForgeTests",
      dependencies: ["Forge"]
    )
  ]
)
