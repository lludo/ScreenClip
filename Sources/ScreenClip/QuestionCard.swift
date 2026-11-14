import ScreenClipCore
import SwiftUI

struct QuestionCard: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  let question: PendingQuestion
  @State private var answers: [String: String] = [:]
  @State private var sending = false
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
        Text(
          question.questions?["command"].string
            ?? "Review the requested change in Codex if you need more detail."
        ).font(.caption.monospaced()).textSelection(.enabled)
        HStack {
          Button("Allow once") { decide(true) }.disabled(sending)
          Button("Decline") { decide(false) }.disabled(sending)
        }
      } else {
        Button("Review request in Codex") { model.openCodex(issue) }
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
      .orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
  private func decide(_ allow: Bool) {
    sending = true
    Task {
      await model.worker.reply(
        issueID: issue.id, questionID: question.id, answers: [:], allow: allow)
      sending = false
    }
  }
}
