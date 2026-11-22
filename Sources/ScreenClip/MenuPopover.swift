import AppKit
import ScreenClipCore
import SwiftUI

struct MenuPopover: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var updater = Updater.shared
  @Environment(\.locale) private var locale
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Label {
          Text(chrome: "ScreenClip", comment: "Product name in the menu bar popover. Do not translate.")
        } icon: {
          Image(systemName: "viewfinder")
        }.font(.headline)
        Spacer(minLength: 8)
        if model.snapshot.settings.paused {
          Text(chrome: "Paused", comment: "Shown in the menu bar when report processing is paused.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Button {
          model.settingsAction?()
        } label: {
          Image(systemName: "gearshape")
        }.buttonStyle(.plain)
          .accessibilityLabel(Text(chrome: "Settings", comment: "Opens Settings from the menu bar."))
      }
      HStack(alignment: .top, spacing: 12) {
        metric(
          Chrome.format(
            "metric.open.caption", "Open", locale: locale,
            comment: "Caption under the open-report count. The number is shown separately."),
          model.snapshot.activeCount,
          phrase: Chrome.format(
            "metric.open.phrase", "\(model.snapshot.activeCount) Open", locale: locale,
            comment: "Accessibility label for the open-report count. %lld is the count."))
        metric(
          Chrome.format(
            "metric.needsYou.caption", "Needs you", locale: locale,
            comment: "Caption under the needs-you count. The number is shown separately."),
          model.snapshot.attentionCount,
          phrase: Chrome.format(
            "metric.needsYou.phrase", "\(model.snapshot.attentionCount) Needs you", locale: locale,
            comment: "Accessibility label for reports that need the user. %lld is the count."))
        metric(
          Chrome.format(
            "metric.retest.caption",
            "To retest", locale: locale,
            comment: "Caption under the retest count. The number is shown separately."),
          retestCount,
          phrase: Chrome.format(
            "metric.retest.phrase", "\(retestCount) To retest", locale: locale,
            comment: "Accessibility label for merged reports waiting to be retested. %lld is the count."))
      }
      HStack(spacing: 8) {
        Button {
          model.captureAction?()
        } label: {
          HStack(spacing: 8) {
            Label {
              Text(chrome: "Screenshot task", comment: "Menu bar button to start a task by capturing a screen region.")
            } icon: {
              Image(systemName: "photo")
            }
            Text(model.snapshot.settings.shortcutDescription).foregroundStyle(.secondary)
          }
          .frame(minWidth: 0, maxWidth: .infinity)
        }
        Button {
          model.textCaptureAction?()
        } label: {
          Label {
            Text(chrome: "Text task", comment: "Menu bar button to start a task by writing a note.")
          } icon: {
            Image(systemName: "text.alignleft")
          }
          .frame(minWidth: 0, maxWidth: .infinity)
        }
      }.buttonStyle(.bordered)
      if let banner = model.banner {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          Text(verbatim: Chrome.stored(banner, locale: locale)).font(.caption).lineLimit(6)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          Spacer(minLength: 4)
          Button {
            model.banner = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).accessibilityLabel(
            Text(chrome: "Dismiss message", comment: "Clears the menu bar banner."))
        }
      }
      Divider()
      if model.snapshot.issues.isEmpty {
        Text(
          chrome: "Your observations will appear here.",
          comment: "Empty state in the menu bar popover."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 110)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(Array(model.snapshot.issues.filter { !$0.archived }.suffix(5).reversed())) {
              issue in
              Button {
                model.selectedIssueID = issue.id
                model.queueAction?()
              } label: {
                IssueRow(issue: issue, project: model.project(issue.projectID))
              }.buttonStyle(.plain)
              Divider()
            }
          }
        }.frame(maxHeight: 245)
      }
      HStack(alignment: .center) {
        Button {
          model.queueAction?()
        } label: {
          Text(chrome: "Open queue", comment: "Opens the report queue window.")
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if let version = updater.pendingVersion {
          Button {
            updater.installPendingUpdate()
          } label: {
            Text(verbatim: Chrome.format(
              "menu.update.install", "Update to \(version)", locale: locale,
              comment: "Installs a downloaded app update. %@ is a version number and is not translated."))
          }.buttonStyle(.borderedProminent).tint(.orange)
        }
        Button {
          model.togglePaused()
        } label: {
          if model.snapshot.settings.paused {
            Text(chrome: "Resume", comment: "Resumes paused report processing.")
          } else {
            Text(chrome: "Pause", comment: "Pauses report processing.")
          }
        }
        Menu {
          #if !SCREENCLIP_APP_STORE
          if updater.isAvailable {
            Button {
              updater.checkForUpdates()
            } label: {
              Text(chrome: "Check for Updates…", comment: "Checks for a newer version of the app.")
            }.disabled(!updater.canCheckForUpdates)
          }
          Button {
            model.supportAction?()
          } label: {
            Text(chrome: "Support ScreenClip…", comment: "Opens the optional tip window.")
          }
          #endif
          Button {
            NSApp.terminate(nil)
          } label: {
            Text(chrome: "Quit ScreenClip", comment: "Quits the app from the menu bar.")
          }
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel(
            Text(chrome: "More options", comment: "Menu for support and quit."))
          .help(Text(chrome: "More options", comment: "Menu for support and quit."))
      }
    }.padding(20).frame(minWidth: 400, idealWidth: 460, maxWidth: 520)
  }
  private var retestCount: Int {
    model.snapshot.issues.filter { $0.status == .merged && !$0.archived }.count
  }
  func metric(_ title: String, _ value: Int, phrase: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value, format: .number).font(.system(size: 24, weight: .semibold, design: .rounded))
        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
      Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: phrase))
  }
}
