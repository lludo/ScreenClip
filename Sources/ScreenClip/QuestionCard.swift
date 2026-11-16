import ScreenClipCore
import SwiftUI

struct QuestionCard: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  let question: PendingQuestion
  @Environment(\.locale) private var locale
  @State private var answers: [String: String] = [:]
  @State private var sending = false
  @State private var confirmingRule = false
  private var approvalOptions: CodexApprovalOptions {
    CodexApprovalOptions(method: question.requestMethod ?? "", params: question.questions ?? .null)
  }
  private var elicitation: CodexMcpElicitation {
    CodexMcpElicitation(params: question.questions ?? .null)
  }
  private var ruleText: String {
    (approvalOptions.commandRule ?? []).map { $0.debugDescription }.joined(separator: " ")
  }
  var queries: [JSONValue] {
    CodexRequestKind(method: question.requestMethod) == .userInput
      ? (question.questions?.array ?? []) : []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label {
        Text(chrome: "Needs your input", comment: "Heading on a pending agent question.")
      } icon: {
        Image(systemName: "bubble.left")
      }.font(.headline).foregroundStyle(.orange)
      Text(verbatim: question.title).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      if question.requestID == nil || !queries.isEmpty {
        if queries.isEmpty {
          TextField(
            "",
            text: Binding(get: { answers["reply"] ?? "" }, set: { answers["reply"] = $0 }),
            prompt: Text(chrome: "Your reply", comment: "Placeholder for a reply to the agent."),
            axis: .vertical
          ).textFieldStyle(.roundedBorder)
        }
        ForEach(Array(queries.enumerated()), id: \.offset) { _, q in
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: q["header"].string ?? q["id"].string ?? Chrome.text(
              "Answer", locale: locale, comment: "Fallback label for an agent question field."))
              .font(.caption).fixedSize(horizontal: false, vertical: true)
            if !q["options"].array.isEmpty {
              HStack {
                ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                  Button {
                    answers[q["id"].string ?? "reply"] = option["label"].string
                  } label: {
                    Text(verbatim: option["label"].string ?? Chrome.text(
                      "Option", locale: locale, comment: "Fallback label for an agent-provided choice."))
                  }
                }
              }
            }
            TextField(
              "",
              text: Binding(
                get: { answers[q["id"].string ?? "reply"] ?? "" },
                set: { answers[q["id"].string ?? "reply"] = $0 }),
              prompt: Text(chrome: "Your answer", comment: "Placeholder for one answer in a structured question.")
            ).textFieldStyle(.roundedBorder)
          }
        }
        Button {
          sending = true
          Task {
            await model.worker.reply(issueID: issue.id, questionID: question.id, answers: answers)
            sending = false
          }
        } label: {
          if sending {
            Text(chrome: "Sending…", comment: "Reply is being sent.")
          } else {
            Text(chrome: "Send reply", comment: "Sends the reply to the agent.")
          }
        }.disabled(
          sending
            || (queries.isEmpty
              ? (answers["reply"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              : queries.contains { (answers[$0["id"].string ?? "reply"] ?? "").isEmpty }))
      } else if CodexRequestKind(method: question.requestMethod).isApproval {
        if let host = question.questions?["networkApprovalContext"]["host"].string {
          Text(verbatim: Chrome.format(
            "question.network", "Network access: \(host)", locale: locale,
            comment: "Codex approval. %@ is a hostname and is not translated."))
            .font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else if let command = question.questions?["command"].string, !command.isEmpty {
          Text(verbatim: command).font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else if let grant = question.questions?["grantRoot"].string, !grant.isEmpty {
          Text(verbatim: grant).font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            chrome: "Review the requested change in Codex if you need more detail.",
            comment: "Shown when a Codex approval request has no command text."
          ).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout {
          if approvalOptions.permits("accept") {
            if issue.turnID != nil && model.worker.jobs.contains(issue.id) {
              Button {
                sending = true
                Task {
                  await model.worker.allowAndAutomate(issueID: issue.id, questionID: question.id)
                  sending = false
                }
              } label: {
                Text(chrome: "Allow and automate this project", comment: "Allows this request once and enables automatic Codex risk review for this project.")
              }.disabled(sending)
            }
            Button { decide(true) } label: {
              Text(chrome: "Allow once", comment: "Approves one Codex command.")
            }.disabled(sending)
          }
          if approvalOptions.permits("acceptForSession") {
            Button { decide(true, decision: .string("acceptForSession")) } label: {
              Text(chrome: "Allow for this chat", comment: "Approves this command for the rest of the chat.")
            }.disabled(sending)
          }
          if approvalOptions.commandRule != nil {
            Button { confirmingRule = true } label: {
              Text(chrome: "Always allow command…", comment: "Saves a Codex command rule.")
            }.disabled(sending)
          }
          if approvalOptions.permits("decline") {
            Button { decide(false) } label: {
              Text(chrome: "Decline", comment: "Declines a Codex command.")
            }.disabled(sending)
          } else if approvalOptions.permits("cancel") {
            Button { decide(false, decision: .string("cancel")) } label: {
              Text(chrome: "Cancel request", comment: "Cancels a Codex approval request.")
            }.disabled(sending)
          }
        }
        .alert(
          Chrome.text("Save Codex command rule?", locale: locale, comment: "Confirms saving a Codex command prefix."),
          isPresented: $confirmingRule
        ) {
          Button { decide(true, decision: approvalOptions.ruleDecision) } label: {
            Text(chrome: "Save and allow", comment: "Saves the Codex command rule and allows it.")
          }
          Button(role: .cancel) {} label: {
            Text(chrome: "Cancel", comment: "Dismisses saving a Codex command rule.")
          }
        } message: {
          Text(verbatim: Chrome.format(
            "question.commandRule",
            "Codex will allow commands matching this prefix in future chats, potentially across projects:\n\n\(ruleText)",
            locale: locale,
            comment: "Explains a saved Codex command rule. %@ is the command prefix and is not translated."))
        }
      } else if CodexRequestKind(method: question.requestMethod) == .mcpElicitation {
        // ScreenClip owns this chat, so Codex Desktop shows it as open elsewhere and cannot answer.
        if let detail = elicitation.detail {
          Text(verbatim: detail).font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout {
          if elicitation.isToolApproval {
            Button { decide(true) } label: {
              Text(chrome: "Allow once", comment: "Approves one Codex command.")
            }.disabled(sending)
            if elicitation.offersPersist("session") {
              Button { decide(true, decision: .string("session")) } label: {
                Text(chrome: "Allow for this chat", comment: "Approves this command for the rest of the chat.")
              }.disabled(sending)
            }
            if elicitation.offersPersist("always") {
              Button { decide(true, decision: .string("always")) } label: {
                Text(chrome: "Always allow", comment: "Approves a Codex tool permission now and in future chats.")
              }.disabled(sending)
            }
          }
          Button { decide(false) } label: {
            Text(chrome: "Decline", comment: "Declines a Codex command.")
          }.disabled(sending)
        }
      } else {
        FlowLayout {
          Button { model.openCodex(issue) } label: {
            Text(chrome: "Review request in Codex", comment: "Opens the Codex chat for a request ScreenClip cannot answer.")
          }
          // ScreenClip owns the chat, so declining here is the only way past an unknown request.
          Button { decide(false) } label: {
            Text(chrome: "Decline", comment: "Declines a Codex command.")
          }.disabled(sending)
        }
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
      .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
  private func decide(_ allow: Bool, decision: JSONValue? = nil) {
    sending = true
    Task {
      await model.worker.reply(
        issueID: issue.id, questionID: question.id, answers: [:], allow: allow,
        approvalDecision: decision)
      sending = false
    }
  }
}
