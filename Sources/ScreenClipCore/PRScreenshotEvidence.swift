import Foundation
import ImageIO

/// Report evidence is committed with the fix on the pull-request branch, and the description links
/// it at that commit. The next commit removes `.screenclip/` again (`removeFromBranch`), so a
/// squash merge never carries screenshots into the base branch; GitHub keeps the evidence commit
/// reachable through `refs/pull/<n>/head` after the branch is deleted.
/// Only the flattened report derivatives are copied; unredacted originals are never read.
public enum PRScreenshotEvidence {
  public static let removalCommitMessage = "Remove ScreenClip evidence before merge"
  /// Check summary after ScreenClip removed `.screenclip/` from a pull request it was about to merge.
  public static let removedBeforeMergeSummary =
    "ScreenClip removed the .screenclip/ files from this pull request before merging. Checks run again on the new commit."

  /// Deletes `.screenclip/` from the worktree's branch in a commit of its own. Returns the new
  /// head, or nil when HEAD has no `.screenclip/` path. Only that folder is committed, whatever
  /// else is staged, and the worktree is otherwise left as it was.
  public static func removeFromBranch(worktree: String) async throws -> String? {
    let paths = try await GitHubService.listScreenclipPaths(revision: "HEAD", cwd: worktree)
    guard ExternalAssistant.containsScreenclipEvidence(paths) else { return nil }
    _ = try await CommandRunner.checked(
      GitWorkspace.git, ["rm", "-r", "-q", "--", ".screenclip"], cwd: worktree)
    _ = try await CommandRunner.checked(
      GitWorkspace.git, ["commit", "-q", "-m", removalCommitMessage, "--", ".screenclip"], cwd: worktree)
    return try await CommandRunner.checked(GitWorkspace.git, ["rev-parse", "HEAD"], cwd: worktree)
  }

  /// Private blob images may need GitHub authentication even when its rendered PR body was
  /// fetched successfully. Only resolve immutable ScreenClip evidence for this report and repo.
  public static func contentsEndpoint(image: URL, pullRequest: URL, issueID: UUID) -> String? {
    let pr = pullRequest.pathComponents
    let path = image.pathComponents
    guard image.scheme == "https", image.host == "github.com", pullRequest.host == "github.com",
      pr.count == 5, pr[3] == "pull", path.count == 11,
      // GitHub owners and repositories are case-insensitive; the remote may differ from the PR URL.
      zip(path[1...2], pr[1...2]).allSatisfy({ $0.caseInsensitiveCompare($1) == .orderedSame }),
      GitHubService.isRepositorySlug(path[1] + "/" + path[2]),
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

  /// Contents endpoints of this report's evidence images in GitHub's rendered description, in
  /// order and without duplicates, so they can be fetched before the description is shown.
  public static func imageEndpoints(html: String, pullRequest: URL, issueID: UUID) -> [String] {
    var seen = Set<String>()
    return images(html, pullRequest, issueID).map(\.endpoint).filter { seen.insert($0).inserted }
  }

  /// Points each evidence `<img>` at `source(endpoint)`, leaving images it returns nil for.
  public static func replacingImageSources(
    html: String, pullRequest: URL, issueID: UUID, with source: (String) -> String?
  ) -> String {
    let text = NSMutableString(string: html)
    for image in images(html, pullRequest, issueID).reversed() {
      guard let value = source(image.endpoint) else { continue }
      text.replaceCharacters(in: image.src, with: value
        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;"))
    }
    return text as String
  }

  private static let imageTag = try! NSRegularExpression(
    pattern: #"(?:<a\b([^>]*)>\s*)?<img\b([^>]*)>"#, options: .caseInsensitive)
  private static let attribute = try! NSRegularExpression(
    pattern: #"(?<![\w-])(src|data-canonical-src|href)\s*=\s*"([^"]*)""#, options: .caseInsensitive)

  /// GitHub may proxy an image through camo, so its canonical source and wrapping link count too.
  private static func images(_ html: String, _ pullRequest: URL, _ issueID: UUID)
    -> [(src: NSRange, endpoint: String)]
  {
    let text = html as NSString
    return imageTag.matches(in: html, range: NSRange(location: 0, length: text.length)).compactMap { tag in
      var src: NSRange?
      var candidates: [String] = []
      for group in [2, 1] where tag.range(at: group).location != NSNotFound {
        for match in attribute.matches(in: html, range: tag.range(at: group)) {
          let name = text.substring(with: match.range(at: 1)).lowercased()
          if group == 2 && name == "src" { src = match.range(at: 2) }
          if group == 1 && name != "href" { continue }
          candidates.append(text.substring(with: match.range(at: 2)).replacingOccurrences(of: "&amp;", with: "&"))
        }
      }
      guard let src, let endpoint = candidates.lazy.compactMap(URL.init(string:)).compactMap({
        contentsEndpoint(image: $0, pullRequest: pullRequest, issueID: issueID)
      }).first else { return nil }
      return (src, endpoint)
    }
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

  /// Publishing strips this revision's evidence right after committing it. Publishing the same
  /// revision again (a CI repair or a base update) brings its After images back from the commit
  /// before that removal, so the new description still shows them. Another revision's images
  /// live under another path and are never reused.
  static func restoreRemovedAfter(_ issue: Issue, _ worktree: String) async throws {
    let relative = directory(for: issue) + "/after"
    let folder = try safeFolder(worktree: worktree, relative: relative)
    guard !FileManager.default.fileExists(atPath: folder.path) else { return }
    // Fails on a branch without commits, which has nothing to restore either.
    let last = try await CommandRunner.run(
      GitWorkspace.git, ["rev-list", "-1", "HEAD", "--", relative], cwd: worktree)
      .output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard GitHubService.isCommit(last) else { return }
    // The newest commit that touched the folder removed it, so its parent holds the images.
    // Nothing to restore when it did not (the folder never reached a commit).
    _ = try await CommandRunner.run(
      GitWorkspace.git, ["checkout", last + "^", "--", relative], cwd: worktree)
  }

  public static func prepare(issue: Issue, worktree: String) async throws {
    let screenshots = issue.captures.enumerated().compactMap { index, capture in
      capture.imagePath.map { (number: index + 1, path: $0) }
    }
    guard !screenshots.isEmpty else { return }
    try await restoreRemovedAfter(issue, worktree)
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

  /// `head` is the commit that contains the evidence. Publishing removes the files in the
  /// commit after it, so the links never point at the pull request's later head.
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
