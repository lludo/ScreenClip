import Foundation
import ImageIO

/// Report evidence lives in the fix commit so PR images survive branch deletion and merging.
/// Only the flattened report derivatives are copied; unredacted originals are never read.
public enum PRScreenshotEvidence {
  /// Private blob images may need GitHub authentication even when its rendered PR body was
  /// fetched successfully. Only resolve immutable ScreenClip evidence for this report and repo.
  public static func contentsEndpoint(image: URL, pullRequest: URL, issueID: UUID) -> String? {
    let pr = pullRequest.pathComponents
    let path = image.pathComponents
    guard image.scheme == "https", image.host == "github.com", pullRequest.host == "github.com",
      pr.count == 5, pr[3] == "pull", path.count == 11,
      path[1...2] == pr[1...2], GitHubService.isRepositorySlug(path[1] + "/" + path[2]),
      ["blob", "raw"].contains(path[3]), GitHubService.isCommit(path[4]),
      path[5] == ".screenclip", path[6] == "pr", UUID(uuidString: path[7]) == issueID,
      path[8].range(of: #"^revision-[1-9][0-9]*$"#, options: .regularExpression) != nil,
      ["before", "after"].contains(path[9]), path[10].lowercased().hasSuffix(".png"),
      !path[10].contains("/"), !path[10].contains("\\")
    else { return nil }
    let encoded = path[5...].map {
      $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }.joined(separator: "/")
    return "repos/\(pr[1])/\(pr[2])/contents/\(encoded)?ref=\(path[4])"
  }

  public static func directory(for issue: Issue) -> String {
    ".screenclip/pr/\(issue.id.uuidString.lowercased())/revision-\(issue.revision)"
  }

  private static func folder(_ issue: Issue, _ worktree: String, _ name: String) throws -> URL {
    try safeFolder(worktree: worktree, relative: directory(for: issue) + "/" + name)
  }

  /// `relative` inside the worktree. The branch can come from the remote, so a committed
  /// symlink in any component must not redirect evidence files.
  static func safeFolder(worktree: String, relative: String) throws -> URL {
    var folder = URL(fileURLWithPath: worktree, isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath()
    for component in relative.split(separator: "/") {
      folder.appendPathComponent(String(component), isDirectory: true)
      let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
      if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
        throw ScreenClipError.message("Screenshot evidence folders must not contain symbolic links.")
      }
    }
    return folder
  }

  private static func png(_ url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw ScreenClipError.message("Screenshot evidence must be a regular PNG file: \(url.lastPathComponent)")
    }
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.png",
      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    else { throw ScreenClipError.message("Invalid PNG screenshot: \(url.lastPathComponent)") }
    return data
  }

  /// A missing retest capture does not hold back the fix: the PR says so and the agent's
  /// summary explains why. Files that are present must still be real PNGs.
  private static func afterFiles(_ issue: Issue, _ worktree: String) throws -> [URL] {
    let directory = try folder(issue, worktree, "after")
    let files = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    let images = files.filter { $0.pathExtension.lowercased() == "png" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in images { _ = try png(file) }
    return images
  }

  static let missingAfterNote =
    "_No After screenshot was captured for this revision. The summary above explains what is missing and why._"

  public static func prepare(issue: Issue, worktree: String) async throws {
    let screenshots = issue.captures.enumerated().compactMap { index, capture in
      capture.imagePath.map { (number: index + 1, path: $0) }
    }
    guard !screenshots.isEmpty else { return }
    let after = try afterFiles(issue, worktree)
    let before = try folder(issue, worktree, "before")
    if FileManager.default.fileExists(atPath: before.path) {
      try FileManager.default.removeItem(at: before)
    }
    try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
    for screenshot in screenshots {
      let data = try png(URL(fileURLWithPath: screenshot.path))
      try data.write(to: before.appendingPathComponent("\(screenshot.number).png"), options: .atomic)
    }
    // Repositories may ignore .screenclip or PNGs. Include the evidence in validation and push.
    _ = try await CommandRunner.checked(
      GitWorkspace.git, ["add", "--force", "--"]
        + screenshots.map { directory(for: issue) + "/before/\($0.number).png" }
        + after.map { directory(for: issue) + "/after/" + $0.lastPathComponent }, cwd: worktree)
  }

  public static func markdown(issue: Issue, worktree: String, remote: String, head: String) throws -> String {
    let screenshots = issue.captures.enumerated().filter { $0.element.imagePath != nil }
    guard !screenshots.isEmpty else { return "" }
    guard let repository = GitHubRepository.parse(remote: remote) else {
      throw ScreenClipError.message("Cannot identify the screenshot repository.")
    }
    let after = try afterFiles(issue, worktree)
    func image(_ relativePath: String, _ label: String) -> String {
      let encoded = relativePath.addingPercentEncoding(withAllowedCharacters:
        CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%")))!
      return "![\(label)](https://github.com/\(repository.slug)/blob/\(head)/\(encoded)?raw=true)"
    }
    let before = try folder(issue, worktree, "before")
    let beforeImages = try screenshots.map { index, _ in
      let filename = "\(index + 1).png"
      _ = try png(before.appendingPathComponent(filename))
      return image(directory(for: issue) + "/before/" + filename, "Before \(index + 1)")
    }
    let afterImages = after.enumerated().map { index, file in
      image(directory(for: issue) + "/after/" + file.lastPathComponent, "After \(index + 1)")
    }
    return "## Before / After\n\n### Before\n\n" + beforeImages.joined(separator: "\n\n")
      + "\n\n### After\n\n" + (afterImages.isEmpty ? missingAfterNote : afterImages.joined(separator: "\n\n"))
  }
}
