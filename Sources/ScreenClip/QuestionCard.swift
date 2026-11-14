import ScreenClipCore
import SwiftUI

struct QuestionCard: View {
  @ObservedObject var model: AppModel
  let issue: Issue
  let question: PendingQuestion
  @Environment(\.locale) private var locale
  @State private var answers: [String: String] = [:]
  @State private var sending = false
  var queries: [JSONValue] {
    question.requestMethod?.contains("requestUserInput") == true
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
      } else if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"]
        .contains(question.requestMethod ?? "")
      {
        if let command = question.questions?["command"].string, !command.isEmpty {
          Text(verbatim: command).font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(
            chrome: "Review the requested change in Codex if you need more detail.",
            comment: "Shown when a Codex approval request has no command text."
          ).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        FlowLayout {
          Button { decide(true) } label: {
            Text(chrome: "Allow once", comment: "Approves one Codex command.")
          }.disabled(sending)
          Button { decide(false) } label: {
            Text(chrome: "Decline", comment: "Declines a Codex command.")
          }.disabled(sending)
        }
      } else {
        Button { model.openCodex(issue) } label: {
          Text(chrome: "Review request in Codex", comment: "Opens the Codex chat for a request ScreenClip cannot answer.")
        }
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
