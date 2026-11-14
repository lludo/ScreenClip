import Foundation
import ScreenClipCore

@main struct ScreenClipProbe {
  static func main() async throws {
    let args = ProcessInfo.processInfo.arguments
    func option(_ flag: String) throws -> String {
      guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else {
        throw ScreenClipError.message(
          "Usage: ScreenClipProbe --codex /path/to/codex --image /path/to/synthetic.png --repo /path/to/disposable-repo"
        )
      }
      return args[i + 1]
    }
    let path = try option("--codex")
    let image = try Data(contentsOf: URL(fileURLWithPath: option("--image")))
    let repo = try option("--repo")
    let client = CodexClient()
    var stream = try await client.connect(path: path)
    let started = try await client.request(
      "thread/start",
      params: .object([
        "cwd": .string(repo), "sandbox": .string("read-only"),
        "approvalPolicy": .string("on-request"),
      ]), timeout: 60)
    guard let thread = started["thread"]["id"].string else {
      throw ScreenClipError.message("No thread ID")
    }
    _ = try await client.request(
      "thread/name/set",
      params: .object([
        "threadId": .string(thread),
        "name": .string("ScreenClip integration test · synthetic screenshot"),
      ]))
    print("thread: \(thread)")
    let schema: JSONValue = .object([
      "type": .string("object"), "additionalProperties": .bool(false),
      "required": .array([.string("outcome"), .string("summary"), .string("question")]),
      "properties": .object([
        "outcome": .object([
          "type": .string("string"),
          "enum": .array([.string("question"), .string("implemented"), .string("blocked")]),
        ]),
        "summary": .object(["type": .string("string")]),
        "question": .object(["type": .string("string")]),
      ]),
    ])
    let first = try await client.request(
      "turn/start",
      params: .object([
        "threadId": .string(thread), "outputSchema": schema,
        "input": .array([
          .object([
            "type": .string("text"),
            "text": .string(
              "This is a ScreenClip integration test using a synthetic screenshot, not a real bug. Do not use any tools or modify files. Look at the screenshot and return outcome question, describe the orange control briefly in summary, and ask whether its width should change in question."
            ),
          ]),
          .object([
            "type": .string("image"),
            "url": .string("data:image/png;base64," + image.base64EncodedString()),
          ]),
        ]),
      ]), timeout: 60)
    let question = try await awaitTurn(
      stream: stream, turn: first["turn"]["id"].string ?? "", client: client)
    guard question["outcome"].string == "question", !(question["question"].string ?? "").isEmpty
    else { throw ScreenClipError.message("Question round trip failed") }
    print("image and question: OK")
    await client.stop()
    stream = try await client.connect(path: path)
    let resumed = try await client.request(
      "thread/resume", params: .object(["threadId": .string(thread), "excludeTurns": .bool(true)]),
      timeout: 60)
    guard resumed["thread"]["id"].string == thread else {
      throw ScreenClipError.message("Resume returned the wrong chat")
    }
    let second = try await client.request(
      "turn/start",
      params: .object([
        "threadId": .string(thread), "outputSchema": schema,
        "input": .array([
          .object([
            "type": .string("text"),
            "text": .string(
              "Test reply: yes, make it wider. Still do not use tools or edit files. Return outcome implemented, summary confirming you received this answer in the same chat (this is a protocol test, no code changed), and an empty question."
            ),
          ])
        ]),
      ]), timeout: 60)
    let result = try await awaitTurn(
      stream: stream, turn: second["turn"]["id"].string ?? "", client: client)
    guard result["outcome"].string == "implemented" else {
      throw ScreenClipError.message("Reply round trip failed")
    }
    let read = try await client.request(
      "thread/read", params: .object(["threadId": .string(thread)]))
    guard read["thread"]["id"].string == thread else {
      throw ScreenClipError.message("Persisted chat could not be read")
    }
    print("restart, resume, reply, and persisted chat: OK")
    print("desktop link: codex://threads/\(thread)")
    await client.stop()
  }
  static func awaitTurn(stream: AsyncStream<JSONValue>, turn: String, client: CodexClient)
    async throws -> JSONValue
  {
    let watchdog = Task {
      try await Task.sleep(nanoseconds: 180_000_000_000)
      await client.stop()
    }
    defer { watchdog.cancel() }
    var final = ""
    for await message in stream {
      let p = message["params"]
      if message["id"] != .null {
        try await client.reject(
          id: message["id"],
          message: "No tools or external actions are allowed in this synthetic test.")
      }
      if message["method"].string == "item/completed", p["item"]["type"].string == "agentMessage" {
        final = p["item"]["text"].string ?? final
      }
      if message["method"].string == "turn/completed", p["turn"]["id"].string == turn {
        guard p["turn"]["status"].string == "completed" else {
          throw ScreenClipError.message(p["turn"]["error"]["message"].string ?? "Turn failed")
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(final.utf8))
      }
    }
    throw ScreenClipError.message("Codex disconnected before the test completed")
  }
}
