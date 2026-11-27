// On iOS this module is part of ScreenClipKit and compiles to nothing outside Debug builds.
#if !os(iOS) || DEBUG

import Foundation
import Network

/// Frames `LinkMessage`s over an `NWConnection`. Handshake messages go in clear; once `channel`
/// is set, every frame is sealed and any clear or unverifiable frame closes the connection.
/// Callbacks arrive on the main queue.
public final class LinkConnection: @unchecked Sendable {
  public let connection: NWConnection
  private let queue = DispatchQueue(label: "ScreenClip.LinkConnection")
  private var channel: SecureChannel?
  private var closed = false
  public var onMessage: ((LinkMessage) -> Void)?
  public var onReady: (() -> Void)?
  public var onClose: ((Error?) -> Void)?

  public init(connection: NWConnection) { self.connection = connection }

  public static func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.connectionTimeout = 8
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.includePeerToPeer = true
    return parameters
  }

  public func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        DispatchQueue.main.async { self.onReady?() }
        self.receiveHeader()
      case .failed(let error):
        self.finish(error)
      case .waiting(let error):
        // Waiting means the peer is not reachable now; report it instead of hanging.
        self.finish(error)
      case .cancelled:
        self.finish(nil)
      default: break
      }
    }
    connection.start(queue: queue)
  }

  /// Seals every later frame in both directions and resumes reading. Reading pauses after each
  /// clear handshake message, so a sealed frame that follows is never read before the keys exist.
  public func secure(_ channel: SecureChannel) {
    queue.async {
      self.channel = channel
      self.receiveHeader()
    }
  }

  /// Resumes reading for one more clear handshake message, when the handshake has another step
  /// before the keys exist.
  public func continueHandshake() {
    queue.async {
      guard self.channel == nil else { return }
      self.receiveHeader()
    }
  }

  public func send(_ message: LinkMessage, completion: ((Error?) -> Void)? = nil) {
    queue.async {
      do {
        let json = try Frame.json(message)
        guard json.count <= Frame.maximumLength - Frame.sealedOverhead else { throw WireError.tooLarge }
        let frame: Data
        if var channel = self.channel {
          frame = Frame.encode(kind: .sealed, payload: try channel.seal(json))
          self.channel = channel
        } else {
          guard message.isHandshake else { throw WireError.authenticationFailed }
          frame = Frame.encode(kind: .plain, payload: json)
        }
        self.connection.send(
          content: frame,
          completion: .contentProcessed { error in
            DispatchQueue.main.async { completion?(error) }
          })
      } catch {
        DispatchQueue.main.async { completion?(error) }
      }
    }
  }

  public func cancel() {
    connection.cancel()
  }

  private func receiveHeader() {
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, error in
      guard let self else { return }
      if let error { return self.finish(error) }
      guard let data, let length = Frame.length(header: data) else {
        return self.finish(done ? nil : WireError.malformed)
      }
      // Hello, challenge, reveal and rejection only carry identity strings, keys and nonces.
      if self.channel == nil, length > 64 * 1024 { return self.finish(WireError.tooLarge) }
      self.receiveBody(length)
    }
  }

  private func receiveBody(_ length: Int) {
    connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
      guard let self else { return }
      if let error { return self.finish(error) }
      guard let data, data.count == length, let kind = Frame.Kind(rawValue: data[data.startIndex]) else {
        return self.finish(WireError.malformed)
      }
      do {
        let payload = data.dropFirst()
        let message: LinkMessage
        if var channel = self.channel {
          guard kind == .sealed else { throw WireError.authenticationFailed }
          message = try Frame.message(channel.open(Data(payload)))
          self.channel = channel
        } else {
          guard kind == .plain else { throw WireError.authenticationFailed }
          message = try Frame.message(Data(payload))
          guard message.isHandshake else { throw WireError.authenticationFailed }
        }
        DispatchQueue.main.async { self.onMessage?(message) }
        if self.channel != nil { self.receiveHeader() }
      } catch {
        self.finish(error)
      }
    }
  }

  private func finish(_ error: Error?) {
    guard !closed else { return }
    closed = true
    connection.cancel()
    DispatchQueue.main.async { self.onClose?(error) }
  }
}

#endif
