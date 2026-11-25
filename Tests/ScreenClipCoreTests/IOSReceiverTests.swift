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

    init(port: NWEndpoint.Port, deviceID: UUID = UUID(), key: SymmetricKey? = nil, pairing: Bool) {
      self.deviceID = deviceID
      self.key = key
      exchange = pairing ? PairingExchange() : nil
      link = LinkConnection(
        connection: NWConnection(host: "127.0.0.1", port: port, using: LinkConnection.tcpParameters()))
      link.onReady = { [unowned self] in
        self.link.send(
          .hello(
            Hello(
              deviceID: self.deviceID, deviceName: "QA iPhone", deviceModel: "iPhone17,1", appName: "Shop",
              bundleID: "com.example.shop", nonce: self.nonce, pairingPublicKey: self.exchange?.publicKey)))
      }
      link.onMessage = { [unowned self] message in
        self.messages.append(message)
        if case .challenge(let challenge) = message {
          if let exchange = self.exchange, let serverKey = challenge.pairingPublicKey,
            let result = try? exchange.complete(
              peerPublicKey: serverKey, clientPublicKey: exchange.publicKey, serverPublicKey: serverKey,
              clientNonce: self.nonce, serverNonce: challenge.nonce)
          {
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
      link.onClose = { [unowned self] _ in self.closed = true }
      link.start()
    }
  }

  private var saved: [IOSReceiver.DeviceRecord] = []

  private func makeReceiver() throws -> (IOSReceiver, NWEndpoint.Port) {
    saved = []
    let receiver = IOSReceiver(
      macID: UUID(), macName: "Test Mac", loadRecords: { [] }, saveRecords: { [weak self] in self?.saved = $0 })
    receiver.start(advertise: false)
    addTeardownBlock { await MainActor.run { receiver.stop() } }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if case .listening(let port) = receiver.state, port != 0 {
        return (receiver, try XCTUnwrap(NWEndpoint.Port(rawValue: port)))
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    throw XCTSkip("Local listener did not start")
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
    // Before confirmation a report is not accepted and the connection is dropped.
    XCTAssertTrue(saved.isEmpty)
    receiver.confirmPairing()
    spin { device.messages.contains { if case .welcome = $0 { return true } else { return false } } }
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.device.id, device.deviceID)
    XCTAssertEqual(saved.first?.key, device.key?.data)
    XCTAssertEqual(receiver.devices.count, 1)
    XCTAssertFalse(receiver.pairingOpen)
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

    // A later session with the stored key delivers a report and gets an ack.
    let key = try XCTUnwrap(pairing.key)
    let device = FakeDevice(port: port, deviceID: pairing.deviceID, key: key, pairing: false)
    let sent = report()
    device.onMessage = { message in
      if case .welcome = message { device.link.send(.report(sent)) }
    }
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
}
