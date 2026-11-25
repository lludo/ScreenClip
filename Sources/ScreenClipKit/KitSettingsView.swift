#if os(iOS) && DEBUG
  import ScreenClipWire
  import SwiftUI

  struct KitSettingsView: View {
    let link: MacLink
    let outbox: Outbox
    @State private var shake = KitPreferences.shakeEnabled
    @State private var screenshotOffer = KitPreferences.screenshotOfferEnabled

    var body: some View {
      Form {
        macSection
        savedSection
        Section {
          Toggle("Shake to report", isOn: $shake)
            .onChange(of: shake) { _, value in KitPreferences.shakeEnabled = value }
          Toggle("Offer to report after a screenshot", isOn: $screenshotOffer)
            .onChange(of: screenshotOffer) { _, value in KitPreferences.screenshotOfferEnabled = value }
        } header: {
          Text("Capture")
        } footer: {
          Text("ScreenClipKit is active only in Debug builds of this app.")
        }
      }
      .navigationTitle("ScreenClip")
      .navigationBarTitleDisplayMode(.inline)
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
            Text("Confirm this code on \(macName)")
              .font(.subheadline)
            Text(code).font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
              .textSelection(.enabled)
            Text("Only confirm if the Mac shows the same code.").font(.caption).foregroundStyle(.secondary)
            Button("Cancel pairing", role: .cancel) { link.cancelPairing() }
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
            if link.connectedMacName == pairing.macName {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
      if link.connectedMacName == pairing.macName { return "Connected" }
      if link.discovered.contains(where: { $0.macID == pairing.macID }) { return "Connecting…" }
      return "Not on this network"
    }

    @ViewBuilder private var savedSection: some View {
      Section {
        if outbox.reports.isEmpty {
          Text("No saved reports. Everything has been sent.").foregroundStyle(.secondary)
        }
        ForEach(outbox.reports) { report in
          VStack(alignment: .leading, spacing: 2) {
            Text(report.note.isEmpty ? "Screenshot" : report.note).lineLimit(2)
            Text(report.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
          }
          .swipeActions {
            Button("Delete", role: .destructive) { outbox.remove(report.id) }
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
        Text("Saved reports (\(outbox.count))")
      } footer: {
        Text("Saved reports are sent automatically when your Mac is reachable. On the Mac you can also click Fetch, or open an exported file.")
      }
    }
  }
#endif
