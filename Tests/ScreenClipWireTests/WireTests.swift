import CryptoKit
import Network
import XCTest

@testable import ScreenClipWire

final class WireTests: XCTestCase {
  func device() -> DeviceContext {
    DeviceContext(
      deviceModel: "iPhone16,1", deviceName: "Test iPhone", osVersion: "18.1", appName: "Demo",
      bundleID: "com.example.demo", appVersion: "1.2", build: "34", gitSHA: "abc1234",
      locale: "en_US", screenWidth: 393, screenHeight: 852, screenScale: 3, orientation: "portrait",
      screenPath: ["UINavigationController", "SettingsViewController"], screenTitle: "Settings")
  }

  func testOlderAnnotationJSONStillDecodes() throws {
    let old = Data(
      #"{"id":"00000000-0000-0000-0000-000000000001","kind":"pen","points":[{"x":0.2,"y":0.3}],"text":""}"#.utf8)
    let mark = try JSONDecoder().decode(Annotation.self, from: old)
    XCTAssertEqual(mark.kind, .pen)
    XCTAssertNil(mark.color)
  }

  func testTestedVersionCombinesVersionBuildAndSHA() {
    XCTAssertEqual(device().testedVersion, "1.2 (34), abc1234")
    var plain = device()
    plain.gitSHA = nil
    XCTAssertEqual(plain.testedVersion, "1.2 (34)")
    XCTAssertEqual(plain.screenName, "Settings")
  }

  func testReportFileRoundTripsAndRejectsNewerFormats() throws {
    let report = WireReport(note: "Button is clipped", image: Data([1, 2, 3]), device: device())
    let decoded = try ReportFile.decode(ReportFile.encode(report))
    XCTAssertEqual(decoded.id, report.id)
    XCTAssertEqual(decoded.note, report.note)
    XCTAssertEqual(decoded.image, report.image)
    XCTAssertEqual(decoded.device, report.device)
    XCTAssertThrowsError(try ReportFile.decode(Data(#"{"format":2}"#.utf8))) {
      XCTAssertEqual($0 as? WireError, .unsupportedFormat)
    }
    XCTAssertThrowsError(try ReportFile.decode(Data("nope".utf8)))
  }

  func testPickedScreenshotRoundTripsAndOlderReportsHaveNone() throws {
    var picked = device()
    picked.pickedScreenshot = PickedScreenshot(takenAt: Date(timeIntervalSince1970: 1_700_000_000), matchesDevice: false)
    let report = WireReport(note: "Old screenshot", image: Data([1]), device: picked)
    let decoded = try ReportFile.decode(ReportFile.encode(report))
    XCTAssertEqual(decoded.device.pickedScreenshot, picked.pickedScreenshot)
    let live = try ReportFile.decode(ReportFile.encode(WireReport(note: "", image: nil, device: device())))
    XCTAssertNil(live.device.pickedScreenshot)
  }

  func testFrameHeaderRejectsOutOfRangeLengths() {
    let frame = Frame.encode(kind: .plain, payload: Data([9, 9]))
    XCTAssertEqual(Frame.length(header: frame.prefix(4)), 3)
    XCTAssertNil(Frame.length(header: Data([0, 0, 0, 0])))
    XCTAssertNil(Frame.length(header: Data([0xFF, 0xFF, 0xFF, 0xFF])))
  }

  func testMessagesRoundTrip() throws {
    let messages: [LinkMessage] = [
      .hello(
        Hello(
          deviceID: UUID(), deviceName: "iPhone", deviceModel: "iPhone16,1", appName: "Demo",
          bundleID: "com.example.demo", nonce: Nonce.make(), pairingCommitment: nil)),
      .pairReveal(publicKey: PairingExchange().publicKey, nonce: Nonce.make()),
      .challenge(Challenge(macID: UUID(), macName: "Mac", nonce: Nonce.make())),
      .rejected(.notPaired), .welcome(macID: UUID(), macName: "Mac"),
      .report(WireReport(note: "n", image: nil, device: device())), .ack(id: UUID()),
      .failed(id: UUID(), message: "x"), .sendPending,
      .queue([QueuedReport(id: UUID(), note: "n", createdAt: Date())]), .track(ids: [UUID()]),
      .reportStates([
        ReportState(
          id: UUID(), reportNumber: 7, title: "t", status: "prOpen", projectName: "Shop", agent: "Codex",
          pullRequestURL: "https://github.com/o/r/pull/1", updatedAt: Date())
      ]), .ping,
    ]
    for message in messages {
      XCTAssertEqual(try Frame.message(Frame.json(message)), message)
    }
  }

  func testPairingProducesTheSameKeyAndCodeOnBothSides() throws {
    let client = PairingExchange()
    let server = PairingExchange()
    let clientNonce = Nonce.make()
    let serverNonce = Nonce.make()
    let a = try client.complete(
      peerPublicKey: server.publicKey, clientPublicKey: client.publicKey,
      serverPublicKey: server.publicKey, clientNonce: clientNonce, serverNonce: serverNonce)
    let b = try server.complete(
      peerPublicKey: client.publicKey, clientPublicKey: client.publicKey,
      serverPublicKey: server.publicKey, clientNonce: clientNonce, serverNonce: serverNonce)
    XCTAssertEqual(a.pairingKey.data, b.pairingKey.data)
    XCTAssertEqual(a.code, b.code)
    XCTAssertEqual(a.code.count, 7)
    // A relay that substitutes its own key shows a different code.
    let relay = PairingExchange()
    let c = try client.complete(
      peerPublicKey: relay.publicKey, clientPublicKey: client.publicKey,
      serverPublicKey: relay.publicKey, clientNonce: clientNonce, serverNonce: serverNonce)
    XCTAssertNotEqual(c.pairingKey.data, b.pairingKey.data)
  }

  func testPairingCommitmentBindsTheKeyAndTheNonce() {
    let key = PairingExchange().publicKey, nonce = Nonce.make()
    let commitment = PairingExchange.commitment(publicKey: key, nonce: nonce)
    XCTAssertEqual(commitment.count, 32)
    XCTAssertTrue(PairingExchange.reveals(commitment, publicKey: key, nonce: nonce))
    XCTAssertFalse(PairingExchange.reveals(commitment, publicKey: PairingExchange().publicKey, nonce: nonce))
    XCTAssertFalse(PairingExchange.reveals(commitment, publicKey: key, nonce: Nonce.make()))
    XCTAssertFalse(PairingExchange.reveals(Data(commitment.dropLast()), publicKey: key, nonce: nonce))
    // Moving bytes between the key and the nonce is a different commitment, and a short nonce
    // is never accepted.
    let moved = PairingExchange.commitment(publicKey: key + nonce.prefix(1), nonce: Data(nonce.dropFirst()))
    XCTAssertNotEqual(moved, commitment)
    XCTAssertFalse(PairingExchange.reveals(moved, publicKey: key + nonce.prefix(1), nonce: Data(nonce.dropFirst())))
    XCTAssertEqual(LinkProtocol.version, 2)
  }

  func testSecureChannelRejectsReplayTamperingAndWrongKeys() throws {
    let key = SymmetricKey(size: .bits256)
    let cn = Nonce.make(), sn = Nonce.make()
    var client = SecureChannel(pairingKey: key, clientNonce: cn, serverNonce: sn, role: .client)
    var server = SecureChannel(pairingKey: key, clientNonce: cn, serverNonce: sn, role: .server)
    let first = try client.seal(Data("one".utf8))
    let second = try client.seal(Data("two".utf8))
    XCTAssertEqual(try server.open(first), Data("one".utf8))
    XCTAssertThrowsError(try server.open(first))  // replay
    var tampered = second
    tampered[0] ^= 1
    XCTAssertThrowsError(try server.open(tampered))
    XCTAssertEqual(try server.open(second), Data("two".utf8))
    XCTAssertEqual(try client.open(server.seal(Data("back".utf8))), Data("back".utf8))
    var stranger = SecureChannel(
      pairingKey: SymmetricKey(size: .bits256), clientNonce: cn, serverNonce: sn, role: .server)
    XCTAssertThrowsError(try stranger.open(try client.seal(Data("x".utf8))))
  }

  func testRendererBurnsInOpaqueRedactionAtPixelSize() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
      data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    let image = context.makeImage()!
    let mark = Annotation(kind: .redact, points: [MarkPoint(0, 0), MarkPoint(0.5, 1)], color: .white)
    let png = try XCTUnwrap(AnnotationDrawing.renderPNG(image: image, marks: [mark, Annotation(kind: .text, points: [MarkPoint(0.6, 0.1)], text: "Hi")]))
    let decoded = try XCTUnwrap(PNG.decode(png))
    XCTAssertEqual(decoded.width, 200)
    XCTAssertEqual(decoded.height, 100)
    let pixels = try XCTUnwrap(decoded.dataProvider?.data as Data?)
    let row = decoded.bytesPerRow
    XCTAssertLessThan(pixels[50 * row + 20 * 4], 10)  // redacted left half is black
    XCTAssertLessThan(pixels[12 * row + 122 * 4], 200)  // text backing, top-left anchored
    XCTAssertGreaterThan(pixels[90 * row + 190 * 4], 240)  // untouched corner stays white
  }

  /// A full exchange over localhost TCP: pairing frames in clear, then sealed frames.
  func testLinkConnectionCarriesSealedFramesOverTCP() throws {
    let listener = try NWListener(using: LinkConnection.tcpParameters(), on: .any)
    let key = SymmetricKey(size: .bits256)
    let received = expectation(description: "server got the sealed report")
    let acked = expectation(description: "client got the ack")
    var server: LinkConnection?
    let report = WireReport(note: "over the wire", image: Data(repeating: 7, count: 300_000), device: device())
    listener.newConnectionHandler = { connection in
      let link = LinkConnection(connection: connection)
      server = link
      var nonce = Data()
      link.onMessage = { message in
        switch message {
        case .hello(let hello):
          nonce = Nonce.make()
          link.send(.challenge(Challenge(macID: UUID(), macName: "Test Mac", nonce: nonce)))
          link.secure(SecureChannel(pairingKey: key, clientNonce: hello.nonce, serverNonce: nonce, role: .server))
          link.send(.welcome(macID: UUID(), macName: "Test Mac"))
        case .report(let incoming):
          XCTAssertEqual(incoming, report)
          received.fulfill()
          link.send(.ack(id: incoming.id))
        default: break
        }
      }
      link.start()
    }
    let ready = expectation(description: "listening")
    listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    listener.start(queue: .main)
    wait(for: [ready], timeout: 5)
    let port = try XCTUnwrap(listener.port)
    let client = LinkConnection(
      connection: NWConnection(host: "127.0.0.1", port: port, using: LinkConnection.tcpParameters()))
    let clientNonce = Nonce.make()
    client.onReady = {
      client.send(
        .hello(
          Hello(
            deviceID: UUID(), deviceName: "iPhone", deviceModel: "x", appName: "Demo",
            bundleID: "com.example.demo", nonce: clientNonce, pairingCommitment: nil)))
    }
    client.onMessage = { message in
      switch message {
      case .challenge(let challenge):
        client.secure(SecureChannel(pairingKey: key, clientNonce: clientNonce, serverNonce: challenge.nonce, role: .client))
      case .welcome:
        client.send(.report(report))
      case .ack(let id):
        XCTAssertEqual(id, report.id)
        acked.fulfill()
      default: break
      }
    }
    client.start()
    wait(for: [received, acked], timeout: 10)
    client.cancel()
    server?.cancel()
    listener.cancel()
  }
}
