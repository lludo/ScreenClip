import CryptoKit
import Network
import ScreenClipCore
import XCTest

/// Drives the Mac receiver over localhost with a scripted device, without Bonjour or the Keychain.
@MainActor final class IOSReceiverTests: XCTestCase {
  final class FakeDevice {
    let link: LinkConnection
    let nonce = Nonce.make()
    let deviceID: UUID
    var exchange: PairingExchange?
    var key: SymmetricKey?
    var messages: [LinkMessage] = []
    var code: String?
    var onMessage: ((LinkMessage) -> Void)?
    var closed = false
    /// What the device sends after the Mac's pairing challenge, in place of its own key and nonce.
    var reveal: ((PairingExchange, Data) -> LinkMessage?)?

    init(
      port: NWEndpoint.Port, deviceID: UUID = UUID(), key: SymmetricKey? = nil, pairing: Bool,
      protocolVersion: Int = LinkProtocol.version, commitment: Data? = nil,
      reveal: ((PairingExchange, Data) -> LinkMessage?)? = nil
    ) {
      self.reveal = reveal
      self.deviceID = deviceID
      self.key = key
      exchange = pairing ? PairingExchange() : nil
      link = LinkConnection(
        connection: NWConnection(host: "127.0.0.1", port: port, using: LinkConnection.tcpParameters()))
      link.onReady = { [weak self] in
        guard let self else { return }
        self.link.send(
          .hello(
            Hello(
              protocolVersion: protocolVersion,
              deviceID: self.deviceID, deviceName: "QA iPhone", deviceModel: "iPhone17,1", appName: "Shop",
              bundleID: "com.example.shop", nonce: self.exchange == nil ? self.nonce : Data(),
              pairingCommitment: commitment
                ?? self.exchange.map { PairingExchange.commitment(publicKey: $0.publicKey, nonce: self.nonce) })))
      }
      link.onMessage = { [weak self] message in
        guard let self else { return }
        self.messages.append(message)
        if case .challenge(let challenge) = message {
          if let exchange = self.exchange, let serverKey = challenge.pairingPublicKey,
            let result = try? exchange.complete(
              peerPublicKey: serverKey, clientPublicKey: exchange.publicKey, serverPublicKey: serverKey,
              clientNonce: self.nonce, serverNonce: challenge.nonce)
          {
            if let reveal = self.reveal {
              if let message = reveal(exchange, self.nonce) { self.link.send(message) }
            } else {
              self.link.send(.pairReveal(publicKey: exchange.publicKey, nonce: self.nonce))
            }
            self.key = result.pairingKey
            self.code = result.code
          }
          if let key = self.key {
            self.link.secure(
              SecureChannel(pairingKey: key, clientNonce: self.nonce, serverNonce: challenge.nonce, role: .client))
          }
        }
        self.onMessage?(message)
      }
      link.onClose = { [weak self] _ in self?.closed = true }
      link.start()
    }
  }

  private var saved: [IOSReceiver.DeviceRecord] = []

  private func makeReceiver(refuseSave: Bool = false) throws -> (IOSReceiver, NWEndpoint.Port) {
    saved = []
    let receiver = IOSReceiver(
      macID: UUID(), macName: "Test Mac", loadRecords: { [] }, saveRecords: { [weak self] records in
        if refuseSave { throw CocoaError(.fileWriteNoPermission) }
        self?.saved = records
      })
    receiver.start(advertise: false)
    addTeardownBlock { await MainActor.run { receiver.stop() } }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if case .listening(let port) = receiver.state, port != 0 {
        return (receiver, try XCTUnwrap(NWEndpoint.Port(rawValue: port)))
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    throw NSError(domain: "IOSReceiverTests", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "The loopback receiver did not start: \(receiver.state)"
    ])
  }

  private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
  }

  private func report() -> WireReport {
    WireReport(note: "Broken layout", image: nil, device: DeviceContext(appName: "Shop", bundleID: "com.example.shop"))
  }

  func testPairingNeedsAnOpenWindowAndConfirmation() throws {
    let (receiver, port) = try makeReceiver()
    // Closed window: refused.
    let early = FakeDevice(port: port, pairing: true)
    spin { early.messages.contains(.rejected(.pairingClosed)) }
    XCTAssertTrue(early.messages.contains(.rejected(.pairingClosed)))

    receiver.openPairing()
    let device = FakeDevice(port: port, pairing: true)
    spin { receiver.pairingRequest != nil && device.code != nil }
    let request = try XCTUnwrap(receiver.pairingRequest)
    XCTAssertEqual(request.code, device.code)
    XCTAssertEqual(request.deviceName, "QA iPhone")
    // Opening the sheet again preserves the request already on screen.
    receiver.openPairing()
    XCTAssertEqual(receiver.pairingRequest, request)
    receiver.confirmPairing(requestID: UUID())
    XCTAssertTrue(saved.isEmpty)
    receiver.confirmPairing(requestID: request.id)
    spin { device.messages.contains { if case .welcome = $0 { return true } else { return false } } }
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.device.id, device.deviceID)
    XCTAssertEqual(saved.first?.key, device.key?.data)
    XCTAssertEqual(receiver.devices.count, 1)
    XCTAssertFalse(receiver.pairingOpen)
  }

  func testARevealThatDoesNotMatchTheCommitmentIsRefused() throws {
    let (receiver, port) = try makeReceiver()
    receiver.openPairing()
    // The device reveals another key than the one its hello committed to.
    let swapped = FakeDevice(port: port, pairing: true, reveal: { _, nonce in
      .pairReveal(publicKey: PairingExchange().publicKey, nonce: nonce)
    })
    spin { swapped.closed }
    XCTAssertTrue(swapped.closed)
    XCTAssertNil(receiver.pairingRequest)
    // The same key with another nonce is refused too.
    let renonced = FakeDevice(port: port, pairing: true, reveal: { exchange, _ in
      .pairReveal(publicKey: exchange.publicKey, nonce: Nonce.make())
    })
    spin { renonced.closed }
    XCTAssertTrue(renonced.closed)
    XCTAssertNil(receiver.pairingRequest)
    XCTAssertTrue(saved.isEmpty)
    // The window is free again for an honest device.
    let device = FakeDevice(port: port, pairing: true)
    spin { receiver.pairingRequest != nil && device.code != nil }
    XCTAssertEqual(receiver.pairingRequest?.code, device.code)
  }

  func testNoCodeIsShownBeforeTheReveal() throws {
    let (receiver, port) = try makeReceiver()
    receiver.openPairing()
    let silent = FakeDevice(port: port, pairing: true, reveal: { _, _ in nil })
    spin { silent.messages.contains { if case .challenge = $0 { return true } else { return false } } }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertNil(receiver.pairingRequest)
    // While one pairing is under way, another device is asked to wait.
    let second = FakeDevice(port: port, pairing: true)
    spin { second.messages.contains(.rejected(.busy)) }
    XCTAssertTrue(second.messages.contains(.rejected(.busy)))
    // Closing the window ends the unfinished pairing.
    receiver.closePairing()
    spin { silent.closed }
    XCTAssertTrue(silent.closed)
  }

  func testAnEarlierProtocolVersionIsRefused() throws {
    let (receiver, port) = try makeReceiver()
    receiver.openPairing()
    let old = FakeDevice(port: port, pairing: true, protocolVersion: 1)
    spin { old.messages.contains(.rejected(.unsupportedVersion)) }
    XCTAssertTrue(old.messages.contains(.rejected(.unsupportedVersion)))
    XCTAssertNil(receiver.pairingRequest)
  }

  func testPairedDeviceDeliversAndUnknownDeviceIsRejected() throws {
    let (receiver, port) = try makeReceiver()
    var imported: [UUID] = []
    receiver.importReport = { report in
      if imported.contains(report.id) { return .duplicate }
      imported.append(report.id)
      return .imported
    }
    receiver.openPairing()
    let pairing = FakeDevice(port: port, pairing: true)
    spin { receiver.pairingRequest != nil }
    receiver.confirmPairing()
    spin { pairing.messages.contains { if case .welcome = $0 { return true } else { return false } } }
    pairing.link.cancel()
    spin { receiver.connected[pairing.deviceID] == nil }

    // A later session with the stored key delivers a report and gets an ack.
    let key = try XCTUnwrap(pairing.key)
    let device = FakeDevice(port: port, deviceID: pairing.deviceID, key: key, pairing: false)
    let sent = report()
    spin { device.messages.contains { if case .welcome = $0 { return true } else { return false } } }
    XCTAssertNil(receiver.connected[pairing.deviceID])
    device.link.send(.report(sent))
    spin { device.messages.contains(.ack(id: sent.id)) }
    XCTAssertEqual(imported, [sent.id])
    XCTAssertNotNil(receiver.connected[pairing.deviceID])
    // The device follows its delivered report and hears about changes.
    var status = "queued"
    let updated = Date()
    receiver.reportStates = { ids in
      ids.map {
        ReportState(
          id: $0, reportNumber: 3, title: "Broken layout", status: status, projectName: "Shop", agent: "Codex",
          pullRequestURL: nil, updatedAt: updated)
      }
    }
    device.link.send(.track(ids: [sent.id]))
    spin { device.messages.contains { if case .reportStates(let s) = $0 { return s.first?.status == "queued" } else { return false } } }
    status = "prOpen"
    receiver.reportsChanged()
    spin { device.messages.contains { if case .reportStates(let s) = $0 { return s.first?.status == "prOpen" } else { return false } } }
    XCTAssertTrue(device.messages.contains { if case .reportStates(let s) = $0 { return s.first?.status == "prOpen" } else { return false } })
    let before = device.messages.count
    receiver.reportsChanged()  // unchanged: nothing resent
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(device.messages.count, before, "\(device.messages.suffix(3))")
    device.link.send(.queue([QueuedReport(id: UUID(), note: "Later", createdAt: Date())]))
    spin { receiver.deviceQueues[pairing.deviceID]?.count == 1 }
    XCTAssertEqual(receiver.connected[pairing.deviceID], 1)
    XCTAssertEqual(receiver.fetch(), 1)
    spin { device.messages.contains(.sendPending) }
    XCTAssertTrue(device.messages.contains(.sendPending))

    // A device the Mac never paired is turned away before any sealed frame.
    let stranger = FakeDevice(port: port, key: SymmetricKey(size: .bits256), pairing: false)
    spin { stranger.messages.contains(.rejected(.notPaired)) }
    XCTAssertTrue(stranger.messages.contains(.rejected(.notPaired)))

    // Claiming a paired device's id without its key fails authentication: nothing is imported.
    let impostor = FakeDevice(port: port, deviceID: pairing.deviceID, key: SymmetricKey(size: .bits256), pairing: false)
    let forged = report()
    impostor.onMessage = { _ in impostor.link.send(.report(forged)) }
    spin { impostor.closed }
    XCTAssertTrue(impostor.closed)
    XCTAssertFalse(imported.contains(forged.id))
  }

  func testForgetRemovesTheKey() throws {
    let (receiver, port) = try makeReceiver()
    receiver.openPairing()
    let device = FakeDevice(port: port, pairing: true)
    spin { receiver.pairingRequest != nil }
    receiver.confirmPairing()
    spin { !self.saved.isEmpty }
    receiver.forget(device.deviceID)
    XCTAssertTrue(saved.isEmpty)
    XCTAssertTrue(receiver.devices.isEmpty)
  }

  func testPairingMustBeStoredBeforeWelcome() throws {
    let (receiver, port) = try makeReceiver(refuseSave: true)
    receiver.openPairing()
    let device = FakeDevice(port: port, pairing: true)
    spin { receiver.pairingRequest != nil }
    receiver.confirmPairing()
    spin { device.closed }
    XCTAssertTrue(receiver.devices.isEmpty)
    XCTAssertTrue(receiver.connected.isEmpty)
    XCTAssertNotNil(receiver.storageError)
    XCTAssertFalse(device.messages.contains { if case .welcome = $0 { return true } else { return false } })
  }
}
