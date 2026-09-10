// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "InformationBar",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "InformationBar", targets: ["InformationBar"])],
  targets: [
    .executableTarget(name: "InformationBar"),
    .testTarget(name: "InformationBarTests", dependencies: ["InformationBar"], path: "tests/Swift"),
  ]
)
