import AppKit
import ScreenClipCore
import SwiftUI

#if !SCREENCLIP_APP_STORE
/// Small tip window for the direct-download build. Amounts are suggestions; GitHub Sponsors takes the payment.
struct DonationPromptView: View {
  var notNow: () -> Void
  var dontAskAgain: () -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(chrome: "ScreenClip is free", comment: "Title of the optional tip window.")
        .font(.title3.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text(
        chrome:
          "If a merged fix saved you time, you can leave a tip. The amounts are suggestions. GitHub Sponsors lets you choose what to pay.",
        comment: "Explains that tips are optional and open GitHub Sponsors."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        ForEach(DonationPromptPolicy.suggestedAmounts, id: \.self) { amount in
          Button {
            NSWorkspace.shared.open(DonationLinks.sponsors)
          } label: {
            Text(amount, format: .currency(code: "USD").precision(.fractionLength(0)))
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
          .accessibilityLabel(
            Text(
              verbatim: Chrome.format(
                "tip.amount", "Tip \(amount) dollars on GitHub Sponsors", locale: locale,
                comment: "Accessibility label for a suggested tip. %lld is the dollar amount.")))
        }
      }
      Text(
        chrome: "Each amount opens GitHub Sponsors.",
        comment: "Clarifies that tip buttons open GitHub Sponsors."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(action: notNow) {
          Text(chrome: "Not now", comment: "Snoozes the tip prompt.")
        }
        Spacer(minLength: 8)
        Button(action: dontAskAgain) {
          Text(chrome: "Don't ask again", comment: "Turns off the automatic tip prompt.")
        }.foregroundStyle(.secondary)
      }
    }
    .padding(22)
    .frame(minWidth: 420, idealWidth: 480)
  }
}
#endif
