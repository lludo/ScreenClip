import ScreenClipCore
import SwiftUI
import WebKit

struct PullRequestCard: View {
  @ObservedObject var model: AppModel
  @ObservedObject var worker: AgentWorker
  let issue: Issue
  let url: URL

  @State private var preview: PullRequestPreviews.Preview?
  @State private var loadError: String?
  @State private var reload = 0
  @State private var confirmMerge = false
  @State private var reviewedHead: String?

  private struct Request: Equatable {
    let head: String?
    let reload: Int
  }

  init(model: AppModel, worker: AgentWorker, issue: Issue, url: URL) {
    self.model = model
    self.worker = worker
    self.issue = issue
    self.url = url
    // A cached description shows at once and is refreshed in place.
    _preview = State(initialValue: PullRequestPreviews.shared.cached(url))
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
      if let preview {
        if preview.description.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(chrome: "No description provided.", comment: "The pull request has an empty description.")
            .foregroundStyle(.secondary)
        } else {
          PullRequestHTML(preview: preview, url: url, issueID: issue.id, gh: gh)
        }
        // A failed refresh keeps the last description, but says it may be out of date.
        if let loadError {
          Text(verbatim: loadError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      } else if let loadError {
        Text(verbatim: loadError).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
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
          reviewedHead = preview?.description.headRefOid
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
      loadError = nil
      do {
        let value = try await PullRequestPreviews.shared.load(url, issueID: issue.id, gh: gh)
        try Task.checkCancellation()
        preview = value
      } catch {
        if !Task.isCancelled { loadError = Chrome.stored(error.localizedDescription, locale: locale) }
      }
    }
  }

  @Environment(\.locale) private var locale
  private var gh: String { AgentDetector.ghPath(model.snapshot.settings) }
  private var canRequestMerge: Bool {
    guard let head = preview?.description.headRefOid, let project = model.project(issue.projectID) else { return false }
    return worker.manualMergeHeads[issue.id] == head && issue.prHead == head
      && !issue.archived && issue.revision == (issue.prRevision ?? issue.coveredRevision)
      && !worker.refreshing.contains(issue.id) && !worker.mergingProjects.contains(project.id)
      && !model.snapshot.settings.paused
  }
}

/// GitHub supplies sanitized, repository-aware HTML. Fit the web content to the native report
/// scroll view, including later image loads, disclosures and changes to the window width.
/// The page stays hidden until it has loaded, so it appears at its final size.
private struct PullRequestHTML: View {
  let preview: PullRequestPreviews.Preview
  let url: URL
  let issueID: UUID
  let gh: String
  @State private var height: CGFloat
  @State private var ready = false
  private let measured: Bool

  init(preview: PullRequestPreviews.Preview, url: URL, issueID: UUID, gh: String) {
    self.preview = preview
    self.url = url
    self.issueID = issueID
    self.gh = gh
    let cached = PullRequestPreviews.shared.heights[url]
    measured = cached != nil
    _height = State(initialValue: cached ?? 24)
  }

  var body: some View {
    Document(preview: preview, url: url, issueID: issueID, gh: gh, height: $height, ready: $ready)
      .frame(maxWidth: .infinity).frame(height: height)
      .opacity(ready ? 1 : 0)
      .overlay {
        if !ready && !measured {
          ProgressView().controlSize(.small)
            .accessibilityLabel(Text(chrome: "Pull request description", comment: "Description loading indicator."))
        }
      }
      .onChange(of: height) { PullRequestPreviews.shared.rememberHeight(height, for: url) }
      .task {
        // A slow external image must not keep the description hidden.
        try? await Task.sleep(for: .seconds(3))
        ready = true
      }
  }

  struct Document: NSViewRepresentable {
    let preview: PullRequestPreviews.Preview
    let url: URL
    let issueID: UUID
    let gh: String
    @Binding var height: CGFloat
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator {
      Coordinator(height: $height, ready: $ready, url: url, issueID: issueID, gh: gh)
    }

    func makeNSView(context: Context) -> WKWebView {
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      config.defaultWebpagePreferences.allowsContentJavaScript = false
      config.setURLSchemeHandler(context.coordinator, forURLScheme: PullRequestPreviews.scheme)
      let controller = config.userContentController
      controller.add(context.coordinator, contentWorld: .defaultClient, name: "contentHeight")
      controller.addScriptMessageHandler(context.coordinator, contentWorld: .defaultClient, name: "evidenceImage")
      controller.addUserScript(WKUserScript(source: """
        const article = document.querySelector('article');
        new ResizeObserver(() => window.webkit.messageHandlers.contentHeight.postMessage(
          Math.ceil(article.getBoundingClientRect().height))).observe(article);
        for (const img of article.querySelectorAll('img')) {
          const retry = async () => {
            img.style.visibility = 'hidden';
            const url = await window.webkit.messageHandlers.evidenceImage.postMessage(
              [img.src, img.closest('a')?.href || '']);
            // An image that still can't load shows as broken, with its alt text, not as a blank gap.
            if (!url) { img.style.visibility = ''; return; }
            const show = () => img.style.visibility = '';
            img.addEventListener('load', show, {once: true});
            img.addEventListener('error', show, {once: true});
            img.src = url;
          };
          if (img.complete && !img.naturalWidth) retry();
          else img.addEventListener('error', retry, {once: true});
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
      let view = FittingWebView(frame: .zero, configuration: config)
      view.navigationDelegate = context.coordinator
      view.setValue(false, forKey: "drawsBackground")
      return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
      guard context.coordinator.html != preview.html else { return }
      context.coordinator.html = preview.html
      context.coordinator.preview = preview
      view.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: \(PullRequestPreviews.scheme):; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
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
          img { max-width: 100%; max-height: var(--fit-height, 80vh); width: auto; height: auto; object-fit: contain; }
          pre, code { font-family: ui-monospace, monospace; background: rgba(128,128,128,.12); border-radius: 4px; }
          code { padding: .1em .3em; } pre { padding: .65em; overflow-x: auto; }
          pre code { padding: 0; background: none; }
          blockquote { padding-left: .8em; border-left: 3px solid gray; }
          table { display: block; overflow-x: auto; border-collapse: collapse; }
          td, th { padding: .3em .6em; border: 1px solid rgba(128,128,128,.4); }
          .task-list-item { list-style: none; }
        </style></head><body><article>\(preview.html)</article></body></html>
        """, baseURL: url)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply,
      WKNavigationDelegate, WKURLSchemeHandler
    {
      var html: String?
      var preview: PullRequestPreviews.Preview?
      let height: Binding<CGFloat>
      let ready: Binding<Bool>
      let url: URL
      let issueID: UUID
      let gh: String

      init(height: Binding<CGFloat>, ready: Binding<Bool>, url: URL, issueID: UUID, gh: String) {
        self.height = height
        self.ready = ready
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

      func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let data = preview?.image(at: url) else {
          task.didFailWithError(URLError(.fileDoesNotExist))
          return
        }
        task.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count,
          textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
      }

      func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

      func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        (webView as? FittingWebView)?.applyFitHeight(force: true)
        // Images have loaded by now; reveal the page at its final height once it has painted.
        webView.callAsyncJavaScript("""
          await new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done)));
          return Math.ceil(document.querySelector('article').getBoundingClientRect().height);
          """, in: nil, in: .defaultClient
        ) { [height, ready] result in
          if case .success(let value) = result, let value = value as? CGFloat, value.isFinite, value > 0 {
            height.wrappedValue = value
          }
          ready.wrappedValue = true
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

/// The description is sized to its content, so the report scroll view owns vertical scrolling.
/// Images are capped at the visible height so a tall screenshot fits on screen.
private final class FittingWebView: WKWebView {
  private var forwardsGesture = false
  private var fitHeight: CGFloat = 0

  override func scrollWheel(with event: NSEvent) {
    // Decide once per gesture so momentum stays with the view that started it; horizontal
    // gestures still scroll wide code blocks and tables inside the description.
    if event.phase == .began || event.phase == .mayBegin || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
      forwardsGesture = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
    }
    if forwardsGesture, let outer = enclosingScrollView { outer.scrollWheel(with: event) }
    else { super.scrollWheel(with: event) }
  }

  override func layout() {
    super.layout()
    applyFitHeight(force: false)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyFitHeight(force: true)
  }

  func applyFitHeight(force: Bool) {
    guard let visible = enclosingScrollView?.contentView.bounds.height ?? window?.contentLayoutRect.height,
      visible > 0 else { return }
    let value = max(120, (visible - 32).rounded())
    guard force || value != fitHeight else { return }
    fitHeight = value
    evaluateJavaScript("document.documentElement.style.setProperty('--fit-height', '\(Int(value))px')",
      in: nil, in: .defaultClient) { _ in }
  }
}

