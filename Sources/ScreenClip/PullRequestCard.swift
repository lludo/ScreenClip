import ScreenClipCore
import SwiftUI
import WebKit

struct PullRequestCard: View {
  @ObservedObject var model: AppModel
  @ObservedObject var worker: AgentWorker
  let issue: Issue
  let url: URL

  @State private var description: GitHubService.PullRequestDescription?
  @State private var loadError: String?
  @State private var reload = 0
  @State private var confirmMerge = false
  @State private var reviewedHead: String?

  private struct Request: Equatable {
    let head: String?
    let reload: Int
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(chrome: "Pull request description", comment: "Heading for the Markdown description from GitHub.")
          .font(.headline)
        Link(destination: url) {
          HStack(spacing: 3) {
            Text(verbatim: "#" + url.lastPathComponent).monospacedDigit()
            Image(systemName: "arrow.up.right")
          }
        }
        .help(Text(chrome: "View pull request", comment: "Opens the report's pull request."))
        Spacer()
        Button {
          reload += 1
          Task {
            if issue.status == .prOpen { await worker.refreshPR(issue.id) }
            else if AgentWorker.awaitsMergeOutsideScreenClip(issue) { await worker.refreshStalledPR(issue.id) }
          }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(chrome: "Refresh PR status", comment: "Refreshes pull request checks. Keep PR."))
        .help(Text(chrome: "Refresh PR status", comment: "Refreshes pull request checks. Keep PR."))
      }
      Divider()
      if let loadError {
        Text(verbatim: loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      } else if let description {
        if description.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(chrome: "No description provided.", comment: "The pull request has an empty description.")
            .foregroundStyle(.secondary)
        } else {
          PullRequestHTML(html: description.bodyHTML, url: url, issueID: issue.id, gh: gh)
        }
      } else {
        ProgressView().controlSize(.small)
          .accessibilityLabel(Text(chrome: "Pull request description", comment: "Description loading indicator."))
      }
      if issue.status == .prOpen {
        Divider()
        if let summary = issue.checkSummary {
          Label {
            Text(verbatim: Chrome.stored(summary, locale: locale))
          } icon: {
            Image(systemName: summary == ExternalAssistant.evidenceStillPresentSummary
              ? "exclamationmark.circle" : "info.circle")
          }.font(.callout).foregroundStyle(
            summary == ExternalAssistant.evidenceStillPresentSummary ? .orange : .secondary)
        }
        Button {
          reviewedHead = description?.headRefOid
          confirmMerge = true
        } label: {
          Text(chrome: "Merge pull request", comment: "Merges the reviewed pull request in ScreenClip.")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canRequestMerge)
        .confirmationDialog(
          Text(chrome: "Merge pull request?", comment: "Asks for confirmation of a squash merge."),
          isPresented: $confirmMerge, titleVisibility: .visible
        ) {
          Button {
            if let reviewedHead {
              Task { await worker.refreshPR(issue.id, mergeReviewedHead: reviewedHead) }
            }
          } label: { Text(chrome: "Merge pull request", comment: "Confirms the pull request merge.") }
          Button(role: .cancel) {} label: { Text(chrome: "Cancel", comment: "Dismisses the merge confirmation.") }
        } message: {
          Text(verbatim: url.path + " → " + (model.project(issue.projectID)?.baseBranch ?? ""))
        }
      }
    }
    .card(Color(nsColor: .controlBackgroundColor))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false) }
    .onAppear {
      if issue.status == .prOpen && worker.manualMergeHeads[issue.id] == nil {
        // PR monitoring is worker-owned and continues if the user selects another report.
        Task { await worker.refreshPR(issue.id) }
      }
    }
    .task(id: Request(head: issue.prHead, reload: reload)) {
      description = nil
      loadError = nil
      do {
        let value = try await GitHubService.description(url: url, gh: gh)
        try Task.checkCancellation()
        description = value
      } catch {
        if !Task.isCancelled { loadError = Chrome.stored(error.localizedDescription, locale: locale) }
      }
    }
  }

  @Environment(\.locale) private var locale
  private var gh: String { AgentDetector.ghPath(model.snapshot.settings) }
  private var canRequestMerge: Bool {
    guard let head = description?.headRefOid, let project = model.project(issue.projectID) else { return false }
    return worker.manualMergeHeads[issue.id] == head && issue.prHead == head
      && !issue.archived && issue.revision == (issue.prRevision ?? issue.coveredRevision)
      && !worker.refreshing.contains(issue.id) && !worker.mergingProjects.contains(project.id)
      && !model.snapshot.settings.paused
  }
}

/// GitHub supplies sanitized, repository-aware HTML. Fit the web content to the native report
/// scroll view, including later image loads, disclosures and changes to the window width.
private struct PullRequestHTML: View {
  let html: String
  let url: URL
  let issueID: UUID
  let gh: String
  @State private var height: CGFloat = 24

  var body: some View {
    Document(html: html, url: url, issueID: issueID, gh: gh, height: $height)
      .frame(maxWidth: .infinity).frame(height: height)
  }

  struct Document: NSViewRepresentable {
    let html: String
    let url: URL
    let issueID: UUID
    let gh: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height, url: url, issueID: issueID, gh: gh) }

    func makeNSView(context: Context) -> WKWebView {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.defaultWebpagePreferences.allowsContentJavaScript = false
      let controller = config.userContentController
      controller.add(context.coordinator, contentWorld: .defaultClient, name: "contentHeight")
      controller.addScriptMessageHandler(context.coordinator, contentWorld: .defaultClient, name: "evidenceImage")
      controller.addUserScript(WKUserScript(source: """
        const article = document.querySelector('article');
        new ResizeObserver(() => window.webkit.messageHandlers.contentHeight.postMessage(
          Math.ceil(article.getBoundingClientRect().height))).observe(article);
        for (const img of article.querySelectorAll('img')) {
          const retry = async () => {
            const url = await window.webkit.messageHandlers.evidenceImage.postMessage(
              [img.src, img.closest('a')?.href || '']);
            if (url) img.src = url;
          };
          if (img.complete && !img.naturalWidth) retry();
          else img.addEventListener('error', retry, {once: true});
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
      let view = WKWebView(frame: .zero, configuration: config)
      view.navigationDelegate = context.coordinator
      view.setValue(false, forKey: "drawsBackground")
      return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
      guard context.coordinator.html != html else { return }
      context.coordinator.html = html
      view.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
        <meta name="referrer" content="no-referrer">
        <style>
          :root { color-scheme: light dark; font: 13px/1.5 -apple-system, sans-serif; }
          body { margin: 0; overflow-wrap: anywhere; }
          article { display: flow-root; }
          article > :first-child { margin-top: 0; } article > :last-child { margin-bottom: 0; }
          h1, h2, h3 { line-height: 1.25; margin: 1em 0 .4em; }
          p, ul, ol, pre, blockquote, table { margin: .6em 0; }
          ul, ol { padding-left: 1.6em; }
          a { color: LinkText; } .anchor { display: none; }
          img { max-width: 100%; height: auto; }
          pre, code { font-family: ui-monospace, monospace; background: rgba(128,128,128,.12); border-radius: 4px; }
          code { padding: .1em .3em; } pre { padding: .65em; overflow-x: auto; }
          pre code { padding: 0; background: none; }
          blockquote { padding-left: .8em; border-left: 3px solid gray; }
          table { display: block; overflow-x: auto; border-collapse: collapse; }
          td, th { padding: .3em .6em; border: 1px solid rgba(128,128,128,.4); }
          .task-list-item { list-style: none; }
        </style></head><body><article>\(html)</article></body></html>
        """, baseURL: url)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
      var html: String?
      let height: Binding<CGFloat>
      let url: URL
      let issueID: UUID
      let gh: String

      init(height: Binding<CGFloat>, url: URL, issueID: UUID, gh: String) {
        self.height = height
        self.url = url
        self.issueID = issueID
        self.gh = gh
      }

      func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void)
      {
        let sources = message.body as? [String] ?? []
        guard let endpoint = sources.compactMap(URL.init(string:)).compactMap({
          PRScreenshotEvidence.contentsEndpoint(image: $0, pullRequest: url, issueID: issueID)
        }).first else { replyHandler(nil, nil); return }
        Task {
          let download = try? await CommandRunner.checked(gh, [
            "api", "--hostname", "github.com", endpoint, "--jq", ".download_url",
          ])
          replyHandler(download?.hasPrefix("https://") == true ? download : nil, nil)
        }
      }

      func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? CGFloat, value.isFinite, value > 0, value != height.wrappedValue {
          height.wrappedValue = value
        }
      }

      func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
      {
        let destination = action.request.url
        if action.navigationType == .linkActivated, let destination,
          ["https", "http"].contains(destination.scheme?.lowercased())
        {
          NSWorkspace.shared.open(destination)
        }
        // Only the initial HTML document loads inside the report.
        decisionHandler(action.navigationType == .other && action.targetFrame?.isMainFrame == true
          && (destination == url || destination?.absoluteString == "about:blank") ? .allow : .cancel)
      }
    }
  }
}
