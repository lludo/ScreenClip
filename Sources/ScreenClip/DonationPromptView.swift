import AppKit
import ScreenClipCore
import SwiftUI

#if !SCREENCLIP_APP_STORE
/// Small tip window for the direct-download build. Amounts are suggestions; GitHub Sponsors takes the payment.
struct DonationPromptView: View {
  var notNow: () -> Void
  var dontAskAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("ScreenClip is free").font(.title3.weight(.semibold))
      Text(
        "If a merged fix saved you time, you can leave a tip. The amounts are suggestions. GitHub Sponsors lets you choose what to pay."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        ForEach(DonationPromptPolicy.suggestedAmounts, id: \.self) { amount in
          Button("$\(amount)") { NSWorkspace.shared.open(DonationLinks.sponsors) }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityLabel("Tip \(amount) dollars on GitHub Sponsors")
        }
      }
      Text("Each amount opens GitHub Sponsors.").font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Not now", action: notNow)
        Spacer()
        Button("Don't ask again", action: dontAskAgain).foregroundStyle(.secondary)
      }
    }
    .padding(22)
    .frame(width: 420)
  }
}
#endif
