import Combine
import Foundation
import ScreenClipCore

@MainActor final class CodexAuthentication: ObservableObject {
  enum State: Equatable {
    case idle, checking, ready, signedOut, awaitingBrowser, awaitingCode
    case failed(String)

    var isPending: Bool { self == .awaitingBrowser || self == .awaitingCode }
    var message: String {
      switch self {
      case .idle: return ProviderPhrase.notConnected.english(.codex)
      case .checking: return ProviderPhrase.checking.english(.codex)
      case .ready: return ProviderPhrase.ready.english(.codex)
      case .signedOut: return ProviderPhrase.signInToStart.english(.codex)
      case .awaitingBrowser: return "Sign in to Codex in your browser"
      case .awaitingCode: return "Sign in to Codex with the one-time code"
      case .failed(let message): return message
      }
    }
  }

  enum Method { case browser, deviceCode }
  typealias Request = @MainActor (String, JSONValue) async throws -> JSONValue
  @Published private(set) var state: State = .idle
  @Published private(set) var loginURL: URL?
  @Published private(set) var userCode: String?
  @Published private(set) var accountDescription: String?
  private(set) var loginID: String?
  private let request: Request
  private let openURL: (URL) -> Bool
  private let statusChanged: (String) -> Void
  private let timeoutNanoseconds: UInt64
  private var operation = UUID()
  private var timeoutTask: Task<Void, Never>?
  private var startingLogin = false
  private var earlyCompletion: JSONValue?

  init(
    request: @escaping Request, openURL: @escaping (URL) -> Bool,
    timeoutNanoseconds: UInt64 = 300_000_000_000,
    statusChanged: @escaping (String) -> Void = { _ in }
  ) {
    self.request = request
    self.openURL = openURL
    self.timeoutNanoseconds = timeoutNanoseconds
    self.statusChanged = statusChanged
  }

  deinit { timeoutTask?.cancel() }

  func check() async {
    guard state != .checking else { return }
    let token = operation
    let previous = state
    transition(.checking)
    do {
      let account = try await readAccount()
      guard token == operation else { return }
      if isAuthenticated(account) {
        let pendingID = loginID
        clearPending()
        describeAccount(account)
        transition(.ready)
        // Cancel only this redundant login attempt, never the saved account session.
        if let pendingID {
          _ = try? await request("account/login/cancel", .object(["loginId": .string(pendingID)]))
        }
      } else {
        accountDescription = nil
        transition(loginID != nil && previous.isPending ? previous : .signedOut)
      }
    } catch {
      guard token == operation else { return }
      transition(.failed(error.localizedDescription))
    }
  }

  func signIn(method: Method = .browser) async {
    guard state != .checking else { return }
    if loginID != nil { await cancel() }
    let token = UUID()
    operation = token
    transition(.checking)
    do {
      let account = try await readAccount()
      guard token == operation else { return }
      if isAuthenticated(account) {
        describeAccount(account)
        transition(.ready)
        return
      }
      accountDescription = nil
      startingLogin = true
      let result = try await request(
        "account/login/start",
        .object([
          "type": .string(method == .browser ? "chatgpt" : "chatgptDeviceCode")
        ]))
      startingLogin = false
      guard token == operation else {
        if let id = result["loginId"].string {
          _ = try? await request("account/login/cancel", .object(["loginId": .string(id)]))
        }
        return
      }
      guard let id = result["loginId"].string, !id.isEmpty else {
        throw ScreenClipError.message(
          "Codex did not return a sign-in attempt ID. Try checking the connection again.")
      }
      loginID = id
      let value = method == .browser ? result["authUrl"].string : result["verificationUrl"].string
      guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else {
        throw ScreenClipError.message("Codex returned an invalid sign-in address.")
      }
      if method == .deviceCode {
        guard let code = result["userCode"].string, !code.isEmpty else {
          throw ScreenClipError.message(
            "Codex did not return a one-time code. Browser sign-in is still available.")
        }
        userCode = code
      }
      loginURL = url
      transition(method == .browser ? .awaitingBrowser : .awaitingCode)
      if let completion = earlyCompletion {
        earlyCompletion = nil
        await handleCompletion(completion)
        if !state.isPending { return }
      }
      guard openURL(url) else {
        throw ScreenClipError.message(
          "The sign-in page could not be opened. Check your default browser and try again.")
      }
      scheduleTimeout(token: token, loginID: id)
    } catch {
      startingLogin = false
      guard token == operation else { return }
      let pendingID = loginID
      clearPending()
      transition(.failed("Codex sign-in failed: " + error.localizedDescription))
      if let pendingID {
        _ = try? await request("account/login/cancel", .object(["loginId": .string(pendingID)]))
      }
    }
  }

  func cancel() async {
    let pendingID = loginID
    reset()
    if let pendingID {
      _ = try? await request("account/login/cancel", .object(["loginId": .string(pendingID)]))
    }
  }

  func reset(message: String? = nil) {
    operation = UUID()
    startingLogin = false
    clearPending()
    accountDescription = nil
    transition(message.map(State.failed) ?? .idle)
  }

  func handleNotification(method: String, params: JSONValue) async {
    if method == "account/login/completed" {
      if startingLogin && loginID == nil {
        earlyCompletion = params
        return
      }
      await handleCompletion(params)
    } else if method == "account/updated", state != .checking {
      if case .failed = state { return }  // Preserve an actionable login failure until the user checks again.
      await check()
    }
  }

  func reopenLoginPage() {
    if let loginURL { _ = openURL(loginURL) }
  }

  private func handleCompletion(_ params: JSONValue) async {
    guard let id = loginID, params["loginId"].string == id else { return }
    clearPending()
    operation = UUID()
    if params["success"].bool == true {
      transition(.idle)
      await check()
    } else {
      let detail =
        params["error"].string.flatMap { $0.isEmpty ? nil : $0 }
        ?? "The browser sign-in did not complete. Check the connection or try another sign-in option."
      transition(.failed("Codex sign-in failed: " + detail))
    }
  }

  private func readAccount() async throws -> JSONValue {
    try await request("account/read", .object(["refreshToken": .bool(false)]))
  }
  private func isAuthenticated(_ response: JSONValue) -> Bool {
    response["account"] != .null || response["requiresOpenaiAuth"].bool == false
  }
  private func describeAccount(_ response: JSONValue) {
    switch response["account"]["type"].string {
    case "chatgpt": accountDescription = "Using your existing Codex ChatGPT sign-in."
    case "apiKey": accountDescription = "Using the API key already configured in Codex."
    default: accountDescription = "Using Codex's configured provider."
    }
  }
  private func transition(_ state: State) {
    self.state = state
    statusChanged(state.message)
  }
  private func clearPending() {
    timeoutTask?.cancel()
    timeoutTask = nil
    loginID = nil
    loginURL = nil
    userCode = nil
    earlyCompletion = nil
  }
  private func scheduleTimeout(token: UUID, loginID: String) {
    timeoutTask?.cancel()
    let duration = timeoutNanoseconds
    timeoutTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: duration) } catch { return }
      guard let self, self.operation == token, self.loginID == loginID else { return }
      self.clearPending()
      self.operation = UUID()
      self.transition(
        .failed(
          "Sign-in did not finish. Check the connection if the browser showed an error, or try sign-in with a code."
        ))
      _ = try? await self.request("account/login/cancel", .object(["loginId": .string(loginID)]))
    }
  }
}
