#if os(iOS) && DEBUG
  import CryptoKit
  import Foundation
  import Network
  import Observation
  import ScreenClipWire
  import dnssd

  /// Finds ScreenClip on Macs on the local network, pairs with one, and delivers saved reports.
  @MainActor @Observable final class MacLink {
    struct DiscoveredMac: Identifiable, Equatable {
      var macID: UUID?
      var name: String
      var endpoint: NWEndpoint
      var id: String { name }
    }
    enum Phase: Equatable {
      case idle, missingInfoPlist, localNetworkDenied, searching
      case connecting(String)
      case pairing(code: String, macName: String)
      case connected(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var discovered: [DiscoveredMac] = []
    private(set) var pairings: [Pairing] = PairingStore.load()
    private(set) var lastError: String?

    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var linkMac: DiscoveredMac?
    @ObservationIgnored private var exchange: PairingExchange?
    @ObservationIgnored private var pendingPairing: Pairing?
    @ObservationIgnored private var clientNonce = Data()
    @ObservationIgnored private var inFlight: UUID?
    @ObservationIgnored private var skipped: Set<UUID> = []
    @ObservationIgnored private var waiters: [UUID: [(token: UUID, done: (Bool) -> Void)]] = [:]
    @ObservationIgnored private var suspended = true

    init(outbox: Outbox) { self.outbox = outbox }

    var isConnected: Bool {
      if case .connected = phase { return true }
      return false
    }
    var connectedMacName: String? {
      if case .connected(let name) = phase { return name }
      return nil
    }
    var hasPairing: Bool { !pairings.isEmpty }

    /// The host's Info.plist must declare the Bonjour service and a Local Network reason.
    static var missingInfoPlistKeys: [String] {
      let info = Bundle.main.infoDictionary ?? [:]
      var missing: [String] = []
      if !((info["NSBonjourServices"] as? [String]) ?? []).contains(LinkProtocol.serviceType) {
        missing.append("NSBonjourServices (\(LinkProtocol.serviceType))")
      }
      if (info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty ?? true {
        missing.append("NSLocalNetworkUsageDescription")
      }
      return missing
    }

    // MARK: Lifecycle

    func resume() {
      suspended = false
      let missing = Self.missingInfoPlistKeys
      guard missing.isEmpty else {
        phase = .missingInfoPlist
        kitLog.error(
          "ScreenClipKit cannot reach your Mac: add \(missing.joined(separator: " and "), privacy: .public) to the Debug Info.plist. Reports are still saved on the device.")
        return
      }
      if browser == nil { startBrowser() }
      if phase == .idle { phase = .searching }
      autoConnect()
    }

    func suspend() {
      suspended = true
      browser?.cancel()
      browser = nil
      closeLink()
      discovered = []
      if phase != .missingInfoPlist { phase = .idle }
    }

    private func startBrowser() {
      let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil),
        using: LinkConnection.tcpParameters())
      browser.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.browserStateChanged(state) }
        }
      }
      browser.browseResultsChangedHandler = { [weak self] results, _ in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.resultsChanged(results) }
        }
      }
      browser.start(queue: .main)
      self.browser = browser
    }

    private func browserStateChanged(_ state: NWBrowser.State) {
      switch state {
      case .failed(let error), .waiting(let error):
        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
          phase = .localNetworkDenied
        } else {
          lastError = error.localizedDescription
        }
        if case .failed = state {
          browser?.cancel()
          browser = nil
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.suspended, self.browser == nil else { return }
            self.startBrowser()
          }
        }
      case .ready:
        if phase == .localNetworkDenied { phase = .searching }
      default: break
      }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
      discovered = results.compactMap { result in
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var macID: UUID?
        if case .bonjour(let txt) = result.metadata, let text = txt[LinkProtocol.txtMacID] {
          macID = UUID(uuidString: text)
        }
        return DiscoveredMac(macID: macID, name: name, endpoint: result.endpoint)
      }.sorted { $0.name < $1.name }
      autoConnect()
    }

    private func autoConnect() {
      guard !suspended, link == nil else { return }
      guard let mac = discovered.first(where: { mac in pairings.contains { $0.macID == mac.macID } }) else {
        return
      }
      connect(to: mac, pairing: false)
    }

    // MARK: Pairing

    func pair(with mac: DiscoveredMac) {
      closeLink()
      lastError = nil
      connect(to: mac, pairing: true)
    }

    func cancelPairing() {
      closeLink()
      phase = .searching
      autoConnect()
    }

    func forget(_ macID: UUID) {
      pairings.removeAll { $0.macID == macID }
      PairingStore.save(pairings)
      if linkMac?.macID == macID { closeLink() }
      if phase != .missingInfoPlist && !suspended { phase = .searching }
    }

    // MARK: Delivery

    func flush() {
      guard isConnected, inFlight == nil, let link else { return }
      guard let next = outbox.reports.first(where: { !skipped.contains($0.id) }) else { return }
      inFlight = next.id
      link.send(.report(next))
    }

    func retryFailed() {
      skipped.removeAll()
      flush()
    }

    /// Calls `done(true)` when the Mac acknowledges the report, or `done(false)` after `timeout`.
    func whenDelivered(_ id: UUID, timeout: TimeInterval, done: @escaping (Bool) -> Void) {
      let token = UUID()
      waiters[id, default: []].append((token, done))
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        guard let self, let index = self.waiters[id]?.firstIndex(where: { $0.token == token }) else { return }
        self.waiters[id]?.remove(at: index)
        done(false)
      }
    }

    private func resolve(_ id: UUID, _ delivered: Bool) {
      let pending = waiters.removeValue(forKey: id) ?? []
      for waiter in pending { waiter.done(delivered) }
    }

    // MARK: Connection

    private func connect(to mac: DiscoveredMac, pairing: Bool) {
      let link = LinkConnection(
        connection: NWConnection(to: mac.endpoint, using: LinkConnection.tcpParameters()))
      self.link = link
      linkMac = mac
      clientNonce = Nonce.make()
      exchange = pairing ? PairingExchange() : nil
      pendingPairing = nil
      phase = .connecting(mac.name)
      link.onReady = { [weak self, weak link] in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          link.send(.hello(self.hello()))
        }
      }
      link.onMessage = { [weak self, weak link] message in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          self.handle(message, on: link)
        }
      }
      link.onClose = { [weak self, weak link] error in
        MainActor.assumeIsolated {
          guard let self, let link, link === self.link else { return }
          self.linkClosed(error)
        }
      }
      link.start()
    }

    private func hello() -> Hello {
      let info = Bundle.main.infoDictionary ?? [:]
      return Hello(
        deviceID: KitPreferences.deviceID, deviceName: UIDeviceName.current,
        deviceModel: UIDeviceName.model,
        appName: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "",
        bundleID: Bundle.main.bundleIdentifier ?? "", nonce: clientNonce,
        pairingPublicKey: exchange?.publicKey)
    }

    private func handle(_ message: LinkMessage, on link: LinkConnection) {
      switch message {
      case .challenge(let challenge):
        if let exchange {
          guard let serverKey = challenge.pairingPublicKey,
            let result = try? exchange.complete(
              peerPublicKey: serverKey, clientPublicKey: exchange.publicKey, serverPublicKey: serverKey,
              clientNonce: clientNonce, serverNonce: challenge.nonce)
          else { return closeLink() }
          pendingPairing = Pairing(
            macID: challenge.macID, macName: challenge.macName, key: result.pairingKey.data, pairedAt: Date())
          link.secure(
            SecureChannel(
              pairingKey: result.pairingKey, clientNonce: clientNonce, serverNonce: challenge.nonce, role: .client))
          phase = .pairing(code: result.code, macName: challenge.macName)
        } else {
          guard let pairing = pairings.first(where: { $0.macID == challenge.macID }) else { return closeLink() }
          link.secure(
            SecureChannel(
              pairingKey: SymmetricKey(data: pairing.key), clientNonce: clientNonce,
              serverNonce: challenge.nonce, role: .client))
        }
      case .welcome(let macID, let macName):
        if var pairing = pendingPairing, pairing.macID == macID {
          pairing.macName = macName
          pairings.removeAll { $0.macID == macID }
          pairings.append(pairing)
          pendingPairing = nil
          exchange = nil
        } else if let index = pairings.firstIndex(where: { $0.macID == macID }) {
          pairings[index].macName = macName
        }
        PairingStore.save(pairings)
        lastError = nil
        phase = .connected(macName)
        link.send(.status(pending: outbox.count))
        flush()
      case .rejected(let reason):
        switch reason {
        case .notPaired:
          if let macID = linkMac?.macID { forget(macID) }
          lastError = "Your Mac no longer knows this device. Pair again."
        case .pairingClosed:
          lastError = "On your Mac, open ScreenClip Settings > iOS and click Pair a device, then try again."
        case .declined:
          lastError = "Pairing was declined on the Mac."
        case .unsupportedVersion:
          lastError = "Update ScreenClip on your Mac to pair with this version of the SDK."
        case .busy:
          lastError = "Your Mac is busy. Try again in a moment."
        }
        closeLink()
        phase = .searching
      case .sendPending:
        retryFailed()
      case .ack(let id):
        outbox.remove(id)
        skipped.remove(id)
        if inFlight == id { inFlight = nil }
        resolve(id, true)
        link.send(.status(pending: outbox.count))
        flush()
      case .failed(let id, let text):
        skipped.insert(id)
        if inFlight == id { inFlight = nil }
        lastError = text
        resolve(id, false)
        flush()
      case .hello, .report, .status, .ping:
        break
      }
    }

    private func linkClosed(_ error: Error?) {
      let wasPairing: Bool
      if case .pairing = phase { wasPairing = true } else { wasPairing = false }
      link = nil
      linkMac = nil
      inFlight = nil
      exchange = nil
      pendingPairing = nil
      if wasPairing, lastError == nil { lastError = "Pairing did not finish." }
      if phase != .missingInfoPlist { phase = suspended ? .idle : .searching }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.autoConnect() }
    }

    private func closeLink() {
      let current = link
      link = nil
      linkMac = nil
      inFlight = nil
      exchange = nil
      pendingPairing = nil
      current?.cancel()
    }
  }

  import UIKit

  @MainActor enum UIDeviceName {
    static var current: String { UIDevice.current.name }
    static var model: String { DeviceInfo.modelIdentifier() }
  }
#endif
