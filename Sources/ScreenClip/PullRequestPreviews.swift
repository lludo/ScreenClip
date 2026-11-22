import Foundation
import ImageIO
import ScreenClipCore

/// Pull request descriptions with their private evidence images, fetched before they are shown
/// and kept for the session. A report then opens complete, instead of showing broken images
/// that resize the page as they resolve. Evidence is pinned to a commit, so it never goes stale.
@MainActor final class PullRequestPreviews {
  static let shared = PullRequestPreviews()
  /// The web view loads prefetched evidence from memory through this scheme.
  nonisolated static let scheme = "screenclip-evidence"

  struct Preview {
    let description: GitHubService.PullRequestDescription
    /// The description with evidence images pointing at `scheme` URLs.
    let html: String
    let endpoints: [String]
    /// PNG data by contents endpoint.
    let images: [String: Data]

    func image(at url: URL) -> Data? {
      guard url.scheme == PullRequestPreviews.scheme, let index = Int(url.lastPathComponent),
        endpoints.indices.contains(index) else { return nil }
      return images[endpoints[index]]
    }
  }

  /// Measured description heights, so a revisited report keeps its layout while it renders.
  var heights: [URL: CGFloat] = [:]
  private var previews: [URL: Preview] = [:]
  private var recent: [URL] = []
  private var loads: [URL: Task<Preview, Error>] = [:]
  private var queued: Set<URL> = []
  private var prefetching: Task<Void, Never>?
  private let limit = 24

  func cached(_ url: URL) -> Preview? { previews[url] }

  /// Fetches the latest description, reusing images already downloaded and joining a fetch
  /// already in progress. The fetch finishes and is cached even if the caller goes away.
  func load(_ url: URL, issueID: UUID, gh: String) async throws -> Preview {
    let task: Task<Preview, Error>
    if let running = loads[url] {
      task = running
    } else {
      let known = previews.values.reduce(into: [String: Data]()) { $0.merge($1.images) { old, _ in old } }
      task = Task.detached { try await Self.fetch(url, issueID: issueID, gh: gh, known: known) }
      loads[url] = task
    }
    do {
      let preview = try await task.value
      finish(url, task, preview)
      return preview
    } catch {
      finish(url, task, nil)
      throw error
    }
  }

  /// Report rows prefetch one at a time so scrolling the queue doesn't start a burst of `gh` calls.
  func prefetch(_ url: URL, issueID: UUID, gh: String) {
    guard previews[url] == nil, loads[url] == nil, queued.insert(url).inserted else { return }
    let previous = prefetching
    prefetching = Task {
      await previous?.value
      if previews[url] == nil { _ = try? await load(url, issueID: issueID, gh: gh) }
      queued.remove(url)
    }
  }

  private func finish(_ url: URL, _ task: Task<Preview, Error>, _ preview: Preview?) {
    guard loads[url] == task else { return }
    loads[url] = nil
    guard let preview else { return }
    previews[url] = preview
    recent.removeAll { $0 == url }
    recent.append(url)
    while recent.count > limit {
      let old = recent.removeFirst()
      previews[old] = nil
      heights[old] = nil
    }
  }

  nonisolated private static func fetch(_ url: URL, issueID: UUID, gh: String, known: [String: Data])
    async throws -> Preview
  {
    let description = try await GitHubService.description(url: url, gh: gh)
    let endpoints = PRScreenshotEvidence.imageEndpoints(
      html: description.bodyHTML, pullRequest: url, issueID: issueID)
    var images = known.filter { endpoints.contains($0.key) }
    await withTaskGroup(of: (String, Data?).self) { group in
      for endpoint in endpoints where images[endpoint] == nil {
        group.addTask { (endpoint, await image(endpoint, gh: gh)) }
      }
      for await (endpoint, data) in group { images[endpoint] = data }
    }
    try Task.checkCancellation()
    // Images that could not be fetched keep their GitHub source and the page's fallback lookup.
    let html = PRScreenshotEvidence.replacingImageSources(
      html: description.bodyHTML, pullRequest: url, issueID: issueID
    ) { endpoint in
      guard images[endpoint] != nil, let index = endpoints.firstIndex(of: endpoint) else { return nil }
      return "\(scheme)://evidence/\(index)"
    }
    return Preview(description: description, html: html, endpoints: endpoints, images: images)
  }

  nonisolated private static let session = URLSession(configuration: .ephemeral)

  nonisolated private static func image(_ endpoint: String, gh: String) async -> Data? {
    guard let link = try? await CommandRunner.checked(gh, [
      "api", "--hostname", "github.com", endpoint, "--jq", ".download_url",
    ]), link.hasPrefix("https://"), let url = URL(string: link),
      let (data, response) = try? await session.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.png"
    else { return nil }
    return data
  }
}
