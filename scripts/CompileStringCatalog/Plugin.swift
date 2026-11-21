import Foundation
import PackagePlugin

@main struct CompileStringCatalog: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    guard let source = target as? SwiftSourceModuleTarget else { return [] }
    let catalog = source.directoryURL.appendingPathComponent("Localizable.xcstrings")
    let output = context.pluginWorkDirectoryURL.appendingPathComponent("Localizations")
    let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    let arguments = ["xcstringstool", "compile", catalog.path, "--output-directory", output.path]

    // Let the catalog compiler declare the .strings and plural .stringsdict files for each language.
    let plan = Process()
    let pipe = Pipe()
    plan.executableURL = xcrun
    plan.arguments = arguments + ["--dry-run"]
    plan.standardOutput = pipe
    try plan.run()
    let paths = pipe.fileHandleForReading.readDataToEndOfFile()
    plan.waitUntilExit()
    guard plan.terminationStatus == 0 else {
      Diagnostics.error("Could not list the localized resources for \(target.name).")
      return []
    }
    let files = String(decoding: paths, as: UTF8.self).split(separator: "\n")
      .map { URL(fileURLWithPath: String($0)) }.sorted { $0.path < $1.path }
    return [.buildCommand(
      displayName: "Compile \(target.name) string catalog",
      executable: xcrun, arguments: arguments, inputFiles: [catalog], outputFiles: files)]
  }
}
