import Foundation

public enum ScreenClipError: LocalizedError {
  case message(String)
  /// The agent answered the request with an error, so it definitely did not happen.
  case refused(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text), .refused(let text): return text
    }
  }
}
