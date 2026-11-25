// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ScreenClip",
  defaultLocalization: "en",
  platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .executable(name: "ScreenClip", targets: ["ScreenClip"]),
    .library(name: "ScreenClipCore", targets: ["ScreenClipCore"]),
    // The in-app iOS SDK. It compiles to an empty stub outside Debug builds.
    .library(name: "ScreenClipKit", targets: ["ScreenClipKit"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "ScreenClipWire"),
    .target(name: "ScreenClipKit", dependencies: ["ScreenClipWire"]),
    .target(
      name: "ScreenClipCore", dependencies: ["CSQLite", "ScreenClipWire"],
      exclude: ["Localizable.xcstrings"], plugins: ["CompileStringCatalog"]),
    .executableTarget(
      name: "ScreenClip", dependencies: ["ScreenClipCore"],
      exclude: ["Localizable.xcstrings"],
      resources: [
        .process("Assets.xcassets"),
        .copy("AgentIcons-LICENSE.txt"),
      ], plugins: ["CompileStringCatalog"]),
    .plugin(name: "CompileStringCatalog", capability: .buildTool(), path: "scripts/CompileStringCatalog"),
    .executableTarget(name: "ScreenClipProbe", dependencies: ["ScreenClipCore"]),
    .testTarget(name: "ScreenClipWireTests", dependencies: ["ScreenClipWire"]),
    .testTarget(name: "ScreenClipCoreTests", dependencies: ["ScreenClipCore"]),
    .testTarget(name: "ScreenClipAppTests", dependencies: ["ScreenClip"]),
  ],
  swiftLanguageModes: [.v5]
)
