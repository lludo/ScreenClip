// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ScreenClip",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "ScreenClip", targets: ["ScreenClip"]),
    .library(name: "ScreenClipCore", targets: ["ScreenClipCore"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(
      name: "ScreenClipCore", dependencies: ["CSQLite"],
      resources: [.process("Localizable.xcstrings")]),
    .executableTarget(
      name: "ScreenClip", dependencies: ["ScreenClipCore"],
      resources: [
        .process("Localizable.xcstrings"), .process("Assets.xcassets"),
        .copy("AgentIcons-LICENSE.txt"),
      ]),
    .executableTarget(name: "ScreenClipProbe", dependencies: ["ScreenClipCore"]),
    .testTarget(name: "ScreenClipCoreTests", dependencies: ["ScreenClipCore"]),
    .testTarget(name: "ScreenClipAppTests", dependencies: ["ScreenClip"]),
  ],
  swiftLanguageModes: [.v5]
)
