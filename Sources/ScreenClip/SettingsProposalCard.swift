import ScreenClipCore
import SwiftUI

/// Settings a coding agent proposed through the MCP server, with Accept and Reject. Nothing
/// changes until the tester accepts, because a validation command runs on this Mac.
struct SettingsProposalCard: View {
  @ObservedObject var model: AppModel
  var proposal: SettingsProposal
  /// The menu bar popover shows a shorter card.
  var compact = false
  @Environment(\.locale) private var locale

  var body: some View {
    if let project = model.project(proposal.projectID) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: "wand.and.sparkles").foregroundStyle(.orange).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Chrome.format(
              "proposal.title", "Suggested settings for \(project.name)", locale: locale,
              comment: "Title of a settings proposal from a coding agent. %@ is the project name."))
              .fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            if let proposer = proposal.proposer {
              Text(verbatim: Chrome.format(
                "proposal.from", "From \(Self.proposerName(proposer))", locale: locale,
                comment: "Who sent a settings proposal. %@ is an app name such as Claude Code."))
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        ForEach(proposal.orderedChanges, id: \.field) { change in
          VStack(alignment: .leading, spacing: 4) {
            label(change.field).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let current = proposal.currentValue(change.field, in: project)
            if !compact {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(chrome: "Current", comment: "Label for a setting's value before a proposed change.")
                  .font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                if current.isEmpty {
                  Text(chrome: "Not set", comment: "A setting that has no value.")
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                  Text(verbatim: current).font(.system(.caption, design: .monospaced))
                    .strikethrough().foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              if !compact {
                Text(chrome: "Proposed", comment: "Label for a setting's value a coding agent proposed.")
                  .font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
              }
              Text(verbatim: change.value).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).lineLimit(compact ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        if let reason = proposal.reason, !compact {
          // The agent's own words, shown as written.
          Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        if proposal.changes[.validationCommand] != nil {
          Text(
            chrome: "This command runs on your Mac before each fix is published. Accept it only if you recognize what it does.",
            comment: "Warning on a proposed validation command."
          ).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        let blocked = proposal.changes[.validationCommand] == nil
          ? 0 : model.reportsBlockedOnValidation(project.id).count
        HStack(spacing: 8) {
          if blocked > 0 {
            Text(verbatim: Chrome.format(
              "proposal.unblocks", "Accepting continues \(blocked) blocked reports.", locale: locale,
              comment: "Under a proposed validation command. %lld is how many reports were waiting for one."))
              .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Button { model.rejectSettingsProposal(proposal.id) } label: {
            Text(chrome: "Reject", comment: "Discards settings a coding agent proposed.")
          }
          Button { model.acceptSettingsProposal(proposal.id) } label: {
            Text(chrome: "Accept", comment: "Saves settings a coding agent proposed.")
          }.buttonStyle(.borderedProminent).tint(.orange)
        }.controlSize(compact ? .small : .regular)
      }
      .padding(compact ? 10 : 14)
      .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }
  }

  @ViewBuilder private func label(_ field: SettingsProposal.Field) -> some View {
    switch field {
    case .validationCommand:
      Text(chrome: "Validation command", comment: "Command that must pass before publishing.")
    case .baseBranch:
      Text(chrome: "Base branch", comment: "Git base branch field. The branch name itself is not translated.")
    }
  }

  /// MCP clients send identifiers such as "claude-code"; product names read better.
  static func proposerName(_ client: String) -> String {
    let lowered = client.lowercased()
    if lowered == "claude-ai" { return "Claude" }
    if lowered.contains("claude") { return "Claude Code" }
    if lowered.contains("codex") { return "Codex" }
    return client
  }
}
