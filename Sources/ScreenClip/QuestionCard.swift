import ScreenClipCore
import SwiftUI

struct QuestionCard: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  let question: PendingQuestion
  @State private var answers: [String: String] = [:]
  @State private var sending = false
  @State private var confirmingRule = false
  private var approvalOptions: CodexApprovalOptions {
    CodexApprovalOptions(method: question.requestMethod ?? "", params: question.questions ?? .null)
  }
  var queries: [JSONValue] {
    question.requestMethod?.contains("requestUserInput") == true
      ? (question.questions?.array ?? []) : []
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Needs your input", systemImage: "bubble.left").font(.headline).foregroundStyle(.orange)
      Text(question.title).textSelection(.enabled)
      if question.requestID == nil || !queries.isEmpty {
        if queries.isEmpty {
          TextField(
            "Your reply",
            text: Binding(get: { answers["reply"] ?? "" }, set: { answers["reply"] = $0 }),
            axis: .vertical
          ).textFieldStyle(.roundedBorder)
        }
        ForEach(Array(queries.enumerated()), id: \.offset) { _, q in
          VStack(alignment: .leading, spacing: 6) {
            Text(q["header"].string ?? q["id"].string ?? "Answer").font(.caption)
            if !q["options"].array.isEmpty {
              HStack {
                ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                  Button(option["label"].string ?? "Option") {
                    answers[q["id"].string ?? "reply"] = option["label"].string
                  }
                }
              }
            }
            TextField(
              "Your answer",
              text: Binding(
                get: { answers[q["id"].string ?? "reply"] ?? "" },
                set: { answers[q["id"].string ?? "reply"] = $0 })
            ).textFieldStyle(.roundedBorder)
          }
        }
        Button(sending ? "Sending…" : "Send reply") {
          sending = true
          Task {
            await model.worker.reply(issueID: issue.id, questionID: question.id, answers: answers)
            sending = false
          }
        }.disabled(
          sending
            || (queries.isEmpty
              ? (answers["reply"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              : queries.contains { (answers[$0["id"].string ?? "reply"] ?? "").isEmpty }))
      } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"]
        .contains(question.requestMethod ?? "")
      {
        if let host = question.questions?["networkApprovalContext"]["host"].string {
          Text("Network access: \(host)").font(.caption.monospaced()).textSelection(.enabled)
        } else {
          Text(
            question.questions?["command"].string
              ?? question.questions?["grantRoot"].string
              ?? "Review the requested change in Codex if you need more detail."
          ).font(.caption.monospaced()).textSelection(.enabled)
        }
        HStack {
          if approvalOptions.permits("accept") {
            Button("Allow once") { decide(true) }.disabled(sending)
          }
          if approvalOptions.permits("acceptForSession") {
            Button("Allow for this chat") { decide(true, decision: .string("acceptForSession")) }
              .disabled(sending)
          }
          if approvalOptions.commandRule != nil {
            Button("Always allow command…") { confirmingRule = true }.disabled(sending)
          }
          if approvalOptions.permits("decline") {
            Button("Decline") { decide(false) }.disabled(sending)
          } else if approvalOptions.permits("cancel") {
            Button("Cancel request") { decide(false, decision: .string("cancel")) }.disabled(sending)
          }
        }
        .alert("Save Codex command rule?", isPresented: $confirmingRule) {
          Button("Save and allow") { decide(true, decision: approvalOptions.ruleDecision) }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Codex will allow commands matching this prefix in future chats, potentially across projects:\n\n" + (approvalOptions.commandRule ?? []).map { $0.debugDescription }.joined(separator: " "))
        }
      } else {
        Button("Review request in Codex") { model.openCodex(issue) }
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
