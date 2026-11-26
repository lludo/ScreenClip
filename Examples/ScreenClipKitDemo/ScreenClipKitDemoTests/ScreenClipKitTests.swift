import XCTest
@testable import ScreenClipKit

#if os(iOS) && DEBUG
import Network
import ScreenClipWire
import UIKit

@MainActor final class ScreenClipKitTests: XCTestCase {
  func testCaptureKeepsTheFullImageAndTheScenesCornerGeometry() throws {
    let scene = try XCTUnwrap(Snapshot.activeScene())
    let host = try XCTUnwrap(Snapshot.appWindow(in: scene, excluding: []))
    let snapshot = try XCTUnwrap(Snapshot.capture(in: scene, excluding: []))
    XCTAssertTrue(host.isKeyWindow)
    XCTAssertEqual(snapshot.image.size, scene.coordinateSpace.bounds.size)
    let original = try XCTUnwrap(snapshot.image.cgImage)
    let exported = try XCTUnwrap(AnnotationDrawing.renderPNG(image: original, marks: []))
    let output = try XCTUnwrap(UIImage(data: exported)?.cgImage)
    XCTAssertEqual(output.width, original.width)
    XCTAssertEqual(output.height, original.height)
    #if compiler(>=6.2)
      if #available(iOS 26.0, *) {
        let reference = UIView(frame: host.bounds)
        reference.cornerConfiguration = .corners(radius: .containerConcentric())
        host.addSubview(reference)
        defer { reference.removeFromSuperview() }
        XCTAssertEqual(snapshot.cornerRadii.topLeading, reference.effectiveRadius(corner: .topLeft))
        XCTAssertEqual(snapshot.cornerRadii.topTrailing, reference.effectiveRadius(corner: .topRight))
        XCTAssertEqual(snapshot.cornerRadii.bottomLeading, reference.effectiveRadius(corner: .bottomLeft))
        XCTAssertEqual(snapshot.cornerRadii.bottomTrailing, reference.effectiveRadius(corner: .bottomRight))
        return
      }
    #endif
    XCTAssertEqual(snapshot.cornerRadii, .init())
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory
  }

  func testPublicCapturePresentsInTheDemoAndRestoresItsKeyWindow() throws {
    let runtime = KitRuntime.shared
    let scene = try XCTUnwrap(Snapshot.activeScene())
    let host = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
    XCTAssertTrue(ScreenClipKit.isActive)
    ScreenClipKit.capture()
    XCTAssertTrue(runtime.overlay.isPresentingSheet)
    XCTAssertTrue(runtime.overlay.windows.contains { $0.isKeyWindow && $0.windowScene === scene })
    ScreenClipKit.capture()
    XCTAssertEqual(runtime.overlay.windows.count, 1)
    runtime.overlay.dismissSheet()
    XCTAssertTrue(host.isKeyWindow)
    XCTAssertFalse(runtime.overlay.isPresentingSheet)
  }

  func testPairAndDeliverOnlyThisMacsReportsBeforeRecordingTheAck() async throws {
    let base = temporaryDirectory()
    let outbox = Outbox(base: base), sent = SentLog(base: base)
    let keys = PairingKeychain<Pairing>(service: "com.example.ScreenClipKitDemo.tests", account: UUID().uuidString)
    defer { try? keys.save([]) }
    let client = MacLink(outbox: outbox, sent: sent, pairingStore: keys)
    let macID = UUID()
    let offline = WireReport(note: "Offline", image: Data([1, 2, 3]), device: DeviceContext())
    var other = WireReport(note: "Another Mac", image: nil, device: DeviceContext())
    other.destination = ReportDestination(macID: UUID(), name: "Other")
    try outbox.add(other)
    try outbox.add(offline)

    let listener = try NWListener(using: LinkConnection.tcpParameters(), on: .any)
    var server: LinkConnection?
    defer { listener.cancel(); server?.cancel() }
    let ready = expectation(description: "Loopback listener ready")
    let delivered = expectation(description: "Received offline report")
    listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    listener.newConnectionHandler = { connection in MainActor.assumeIsolated {
      let session = LinkConnection(connection: connection)
      server = session
      session.onMessage = { [weak session] message in
        guard let session else { return }
        switch message {
        case .hello(let hello):
          do {
            let publicKey = try XCTUnwrap(hello.pairingPublicKey)
            let exchange = PairingExchange(), nonce = Nonce.make()
            let result = try exchange.complete(peerPublicKey: publicKey, clientPublicKey: publicKey,
              serverPublicKey: exchange.publicKey, clientNonce: hello.nonce, serverNonce: nonce)
            session.send(.challenge(Challenge(macID: macID, macName: "Test Mac", nonce: nonce, pairingPublicKey: exchange.publicKey)))
            session.secure(SecureChannel(pairingKey: result.pairingKey, clientNonce: hello.nonce, serverNonce: nonce, role: .server))
            session.send(.welcome(macID: macID, macName: "Test Mac"))
          } catch { XCTFail("Pairing failed: \(error)") }
        case .report(let report):
          XCTAssertEqual(report.id, offline.id)
          XCTAssertEqual(report.destination?.macID, macID)
          delivered.fulfill()
        default: break
        }
      }
      session.start()
    } }
    listener.start(queue: .main)
    await fulfillment(of: [ready], timeout: 5)
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port))
    client.pair(with: MacLink.DiscoveredMac(macID: macID, name: "Test Mac", endpoint: endpoint))
    await fulfillment(of: [delivered], timeout: 5)
    XCTAssertEqual(try keys.load().map(\.macID), [macID])
    XCTAssertTrue(sent.entries.isEmpty)
    XCTAssertEqual(try ReportFile.read(from: outbox.url(for: offline.id)).destination?.macID, macID)
    let acked = expectation(description: "Stored acknowledgment")
    client.whenDelivered(offline.id, timeout: 5) { success in
      XCTAssertTrue(success)
      acked.fulfill()
    }
    server?.send(.ack(id: offline.id))
    await fulfillment(of: [acked], timeout: 6)
    XCTAssertEqual(Outbox(base: base).reports.map(\.id), [other.id])
    XCTAssertEqual(SentLog(base: base).trackedIDs(macID: macID, name: "Test Mac"), [offline.id])
  }

  func testOfflineReportAndDestinationSurviveRelaunch() throws {
    let base = temporaryDirectory()
    let outbox = Outbox(base: base)
    var report = WireReport(note: "Layout", image: Data(repeating: 42, count: 200_000), device: DeviceContext())
    report.followUpOf = UUID()
    report.destination = ReportDestination(macID: UUID(), name: "Office")
    try outbox.add(report)
    let reopened = Outbox(base: base)
    XCTAssertEqual(reopened.reports.map(\.id), [report.id])
    XCTAssertEqual(reopened.reports.first?.destination, report.destination)
    XCTAssertEqual(try ReportFile.read(from: reopened.url(for: report.id)), report)
    try reopened.remove(report.id)
    XCTAssertEqual(Outbox(base: base).count, 0)
  }

  func testSentReportsFollowMacIdentityAcrossRenamesAndLegacyHistory() throws {
    let base = temporaryDirectory()
    let outbox = Outbox(base: base)
    let oldID = UUID(), mac = UUID(), other = UUID()
    let legacy = SentLog.Entry(id: oldID, note: "Older report", createdAt: Date(), sentAt: Date(), macName: "Home")
    let history = outbox.directory.deletingLastPathComponent().appendingPathComponent("sent.json")
    try JSONEncoder().encode([legacy]).write(to: history)
    let sent = SentLog(base: base)
    XCTAssertEqual(sent.trackedIDs(macID: mac, name: "Home"), [oldID])
    let state = ReportState(id: oldID, reportNumber: 1, title: "Old", status: "merged", projectName: nil,
      agent: nil, pullRequestURL: nil, updatedAt: Date())
    sent.update([state], macID: mac, name: "Home")
    var removed = state
    removed.status = ReportState.removed
    sent.update([removed], macID: other, name: "Home")
    XCTAssertTrue(sent.trackedIDs(macID: other, name: "Home").isEmpty)
    XCTAssertEqual(sent.trackedIDs(macID: mac, name: "Renamed"), [oldID])
    XCTAssertEqual(SentLog(base: base).entries.first?.state, state)
  }

  func testTimeoutDoesNotWaitForABlockedLogReader() async {
    let (release, gate) = AsyncStream<Void>.makeStream()
    // Model a synchronous log call that cannot be interrupted by Task.cancel().
    let blocked = Task.detached { var iterator = release.makeAsyncIterator(); return await iterator.next() }
    let reader = Task<Int?, Never> { _ = await blocked.value; return 7 }
    let safety = Task { try await Task.sleep(for: .seconds(3)); gate.finish() }
    defer { gate.finish(); safety.cancel() }
    let clock = ContinuousClock()
    let start = clock.now
    let result = await KitRuntime.value(of: reader, timeout: 0.03)
    XCTAssertNil(result)
    XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
  }

  func testDiagnosticFramesHandleSentinelCoordinates() {
    XCTAssertEqual(Diagnostics.rounded(.infinite), [0, 0, 0, 0])
    XCTAssertEqual(Diagnostics.rounded(CGRect(x: 2.5, y: -4, width: 8, height: 12)), [3, -4, 8, 12])
  }

  func testViewTreePreservesLabelsAndChildrenInCompactJSON() throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    window.isHidden = false
    let label = UILabel()
    label.accessibilityIdentifier = "report-note"
    label.isAccessibilityElement = true
    label.accessibilityLabel = "First line\nSecond line"
    window.addSubview(label)
    let data = try XCTUnwrap(Diagnostics.viewTree(of: window)?.data)
    XCTAssertFalse(data.contains(0x0A))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let children = try XCTUnwrap(root["children"] as? [[String: Any]])
    let child = try XCTUnwrap(children.first { $0["id"] as? String == "report-note" })
    XCTAssertEqual(child["label"] as? String, label.accessibilityLabel)
  }

  func testRedactionNeedsSeparateOptInToDiagnostics() {
    let original = KitPreferences.attachDiagnostics
    defer { KitPreferences.attachDiagnostics = original }
    let composer = ComposerModel()
    composer.attachDiagnostics = true
    composer.add(Annotation(kind: .redact, points: [MarkPoint(0, 0), MarkPoint(1, 1)]))
    XCTAssertFalse(composer.attachDiagnostics)
    XCTAssertTrue(KitPreferences.attachDiagnostics)
    composer.attachDiagnostics = true
    XCTAssertTrue(composer.attachDiagnostics)
    let next = ComposerModel()
    next.add(Annotation(kind: .redact, points: [MarkPoint(0, 0), MarkPoint(1, 1)]))
    XCTAssertFalse(next.attachDiagnostics)
    next.undo()
    XCTAssertTrue(next.attachDiagnostics)
  }
}
#endif
