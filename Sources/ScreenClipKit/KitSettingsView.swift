#if os(iOS) && DEBUG
  import ScreenClipWire
  import SwiftUI

  struct KitSettingsView: View {
    let link: MacLink
    let outbox: Outbox
    /// "Still broken": the next capture is added to this report.
    var stillBroken: (SentLog.Entry) -> Void = { _ in }
    @State private var shake = KitPreferences.shakeEnabled
    @State private var screenshotOffer = KitPreferences.screenshotOfferEnabled

    var body: some View {
      Form {
        macSection
        savedSection
        Section {
          if KitRuntime.shared.options.triggers.contains(.shake) {
            Toggle("Shake to report", isOn: $shake)
              .onChange(of: shake) { _, value in KitPreferences.shakeEnabled = value }
          }
          if KitRuntime.shared.options.triggers.contains(.screenshot) {
            Toggle("Offer to report after a screenshot", isOn: $screenshotOffer)
              .onChange(of: screenshotOffer) { _, value in KitPreferences.screenshotOfferEnabled = value }
          }
        } header: {
          Text("Capture")
        } footer: {
          Text("ScreenClipKit is active only in Debug builds of this app.")
        }
      }
      .navigationTitle("ScreenClip")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { link.refreshStatuses() }
      .onAppear { link.refreshStatuses() }
    }

    @ViewBuilder private var macSection: some View {
      Section {
        switch link.phase {
        case .missingInfoPlist:
          Label {
            Text(
              "This app's Debug Info.plist is missing \(MacLink.missingInfoPlistKeys.joined(separator: " and ")). Reports are saved on this device until it is fixed."
            )
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
        case .localNetworkDenied:
          Label {
            Text("Local Network access is off for this app. Turn it on in Settings > Privacy & Security > Local Network.")
          } icon: {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
          }
        case .pairing(let code, let macName):
          VStack(alignment: .leading, spacing: 8) {
            Text("Compare this code with \(macName)")
              .font(.subheadline)
            Text(code).font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
              .textSelection(.enabled)
            Text("Confirm here and on the Mac only if both show the same code.")
              .font(.caption).foregroundStyle(.secondary)
            // Two buttons in one row: without a style of their own, a tap on the row presses both.
            if link.pairingConfirmed {
              Text("Waiting for the Mac…").font(.subheadline).foregroundStyle(.secondary)
            } else {
              Button("Codes match") { link.confirmPairing() }.buttonStyle(.borderedProminent)
            }
            Button("Cancel pairing", role: .cancel) { link.cancelPairing() }.buttonStyle(.borderless)
          }
          .padding(.vertical, 4)
        default:
          EmptyView()
        }
        ForEach(link.pairings) { pairing in
          HStack {
            Image(systemName: "desktopcomputer")
            VStack(alignment: .leading) {
              Text(pairing.macName)
              Text(status(for: pairing)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if link.connectedMacID == pairing.macID {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let mac = link.discovered.first(where: { $0.macID == pairing.macID }) {
              Button("Connect") { link.switchTo(mac) }.buttonStyle(.bordered)
            }
          }
          .swipeActions {
            Button("Forget", role: .destructive) { link.forget(pairing.macID) }
          }
        }
        ForEach(unpairedMacs) { mac in
          HStack {
            Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
            Text(mac.name)
            Spacer()
            Button("Pair") { link.pair(with: mac) }
              .buttonStyle(.bordered)
              .disabled({ if case .pairing = link.phase { return true } else { return false } }())
          }
        }
        if link.pairings.isEmpty, unpairedMacs.isEmpty, link.phase == .searching {
          HStack(spacing: 8) {
            ProgressView()
            Text("Looking for ScreenClip on this network…").foregroundStyle(.secondary)
          }
        }
        if let error = link.lastError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      } header: {
        Text("Mac")
      } footer: {
        Text(
          "On your Mac, open ScreenClip Settings > iOS, turn on the local server, and click Pair a device. Your iPhone and Mac must be on the same network."
        )
      }
    }

    private var unpairedMacs: [MacLink.DiscoveredMac] {
      link.discovered.filter { mac in !link.pairings.contains { $0.macID == mac.macID } }
    }

    private func status(for pairing: Pairing) -> String {
      if link.connectedMacID == pairing.macID { return "Connected" }
      if link.discovered.contains(where: { $0.macID == pairing.macID }) { return "Available" }
      return "Not on this network"
    }

    @ViewBuilder private var savedSection: some View {
      Section {
        if outbox.reports.isEmpty {
          Text("Nothing waiting. Everything has been sent.").foregroundStyle(.secondary)
        }
        ForEach(outbox.reports) { report in
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text(report.note.isEmpty ? "Screenshot" : report.note).lineLimit(2)
              Text(report.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: link.inFlight == report.id ? "Sending" : "Waiting", color: .orange)
          }
          .swipeActions {
            Button("Delete", role: .destructive) {
              link.deleteSaved(report.id)
            }.disabled(link.inFlight == report.id)
          }
        }
        if !outbox.reports.isEmpty {
          if link.isConnected {
            Button("Send now") { link.retryFailed() }
          }
          ShareLink(items: outbox.reports.map { outbox.url(for: $0.id) }) {
            Label("Export or AirDrop to your Mac", systemImage: "square.and.arrow.up")
          }
        }
      } header: {
        Text("Waiting to send (\(outbox.count))")
      } footer: {
        Text("Waiting reports are sent automatically when your Mac is reachable. On the Mac you can also click Fetch, or open an exported file.")
      }
      Section {
        if link.sent.entries.isEmpty {
          Text("No reports sent yet.").foregroundStyle(.secondary)
        }
        ForEach(link.sent.entries) { entry in
          SentRow(
            entry: entry, connected: link.isDestination(entry.destination),
            verify: { link.verify(entry.id) }, stillBroken: { stillBroken(entry) }
          )
            .swipeActions {
              Button("Hide", role: .destructive) { link.sent.remove(entry.id) }
            }
        }
      } header: {
        Text("Sent to Mac")
      } footer: {
        Text(link.isConnected
          ? "Status updates live while your Mac is connected. Pull down to refresh."
          : "Status shown as of the last connection to your Mac.")
      }
    }
  }

  struct SentRow: View {
    let entry: SentLog.Entry
    var connected = false
    var verify: () -> Void = {}
    var stillBroken: () -> Void = {}
    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          if let number = entry.state?.reportNumber {
            Text("#\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
          }
          Text(title).lineLimit(2)
          Spacer()
          StatusPill(text: Self.statusTitle(entry.state?.status), color: Self.statusColor(entry.state?.status))
        }
        HStack(spacing: 6) {
          Text(entry.sentAt, style: .relative)
          if let project = entry.state?.projectName { Text("· \(project)") }
          if let agent = entry.state?.agent, entry.state?.status != ReportState.removed { Text("· \(agent)") }
          Spacer()
          if let link = entry.state?.pullRequestURL, let url = URL(string: link) {
            Link("Pull request", destination: url)
          }
        }
        .font(.caption).foregroundStyle(.secondary)
        if entry.state?.status == "merged" || entry.state?.status == "verified" {
          HStack(spacing: 10) {
            if entry.state?.status == "merged" {
              Button("Looks fixed", action: verify).disabled(!connected)
            }
            Button("Still broken", action: stillBroken)
          }
          .buttonStyle(.bordered).controlSize(.small)
          if entry.state?.status == "merged" {
            Text("Merged. Install the latest build, retest, then tell the agent.")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }

    private var title: String {
      if let title = entry.state?.title, !title.isEmpty { return title }
      return entry.note.isEmpty ? "Screenshot" : entry.note
    }

    static func statusTitle(_ status: String?) -> String {
      switch status {
      case nil: return "Sent"
      case "draft": return "Draft"
      case "needsProject": return "Needs project"
      case "queued": return "Queued"
      case "working": return "Agent working"
      case "needsYou": return "Needs you"
      case "prOpen": return "PR open"
      case "merged": return "Merged"
      case "verified": return "Verified"
      case "failed": return "Failed"
      case "canceled": return "Canceled"
      case ReportState.removed: return "Removed on Mac"
      default: return status ?? "Sent"
      }
    }

    static func statusColor(_ status: String?) -> Color {
      switch status {
      case "working", "queued": return .blue
      case "prOpen": return .purple
      case "merged", "verified": return .green
      case "needsYou", "needsProject", "failed": return .orange
      default: return .secondary
      }
    }
  }

  struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
      Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
  }
#endif
