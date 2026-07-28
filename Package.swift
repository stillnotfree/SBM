// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "SBM",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "SBM", targets: ["SBM"]),
    .executable(name: "SBMHelper", targets: ["SBMHelper"]),
  ],
  targets: [
    .target(name: "SBMShared"),
    .executableTarget(
      name: "SBM",
      dependencies: ["SBMShared"]
    ),
    .executableTarget(
      name: "SBMHelper",
      dependencies: ["SBMShared"]
    ),
    .testTarget(
      name: "SBMTests",
      dependencies: ["SBM", "SBMHelper", "SBMShared"]
    ),
  ]
)
