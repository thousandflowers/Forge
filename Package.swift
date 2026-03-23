// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Shift",
  platforms: [
    .macOS(.v12)  // Monterey
  ],
  products: [
    .executable(
      name: "Shift",
      targets: ["Shift"]
    ),
    .library(
      name: "ShiftCore",
      targets: ["Shift"]
    )
  ],
  targets: [
    .executableTarget(
      name: "Shift",
      dependencies: []
    ),
    .testTarget(
      name: "ShiftTests",
      dependencies: ["Shift"]
    )
  ]
)
