import ScreenClipCore
import SwiftUI

/// Template images follow the surrounding text color, like SF Symbols.
struct AgentIcon: View {
  let kind: AgentKind
  var body: some View {
    Image(assetName, bundle: AppLocalization.bundle)
      .renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14)
      .accessibilityHidden(true)
  }
  private var assetName: String {
    switch kind {
    case .codex: return "codex"
    case .claude: return "claude"
    case .external: return "grok"
    }
  }
}

struct AgentLabel: View {
  let kind: AgentKind
  var title: String? = nil
  var body: some View {
    Label { Text(title ?? kind.title) } icon: { AgentIcon(kind: kind) }
  }
}
