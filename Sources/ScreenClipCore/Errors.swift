import Foundation

public enum ScreenClipError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}
