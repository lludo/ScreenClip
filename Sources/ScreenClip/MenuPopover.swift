import AppKit
import ScreenClipCore
import SwiftUI

struct MenuPopover: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var updater = Updater.shared
  @Environment(\.locale) private var locale
  /// The list shown under the counts. Each count picks the queue list it describes.
  @State private var list: QueueFilter
  init(model: AppModel, list: QueueFilter = .active) {
    self.model = model
    _list = State(initialValue: list)
  }
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
      HStack(alignment: .top, spacing: 4) {
        metric(
          Chrome.format(
            "metric.open.caption", "Open", locale: locale,
            comment: "Caption under the open-report count. The number is shown separately."),
          count(.active), list: .active,
          phrase: Chrome.format(
            "metric.open.phrase", "\(count(.active)) Open", locale: locale,
            comment: "Accessibility label for the open-report count. %lld is the count."))
        metric(
          Chrome.format(
            "metric.needsYou.caption", "Needs you", locale: locale,
            comment: "Caption under the needs-you count. The number is shown separately."),
          count(.attention), list: .attention,
          phrase: Chrome.format(
            "metric.needsYou.phrase", "\(count(.attention)) Needs you", locale: locale,
            comment: "Accessibility label for reports that need the user. %lld is the count."))
        metric(
          Chrome.format(
            "metric.retest.caption",
            "To retest", locale: locale,
            comment: "Caption under the retest count. The number is shown separately."),
          count(.retest), list: .retest,
          phrase: Chrome.format(
            "metric.retest.phrase", "\(count(.retest)) To retest", locale: locale,
            comment: "Accessibility label for merged reports waiting to be retested. %lld is the count."))
      }
      // The selection pill extends past the numbers so they stay aligned with the title.
      .padding(.horizontal, -8)
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
      } else if listed.isEmpty {
        Text(chrome: "Nothing here yet", comment: "Empty report list title.")
          .font(.callout).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 110)
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(listed) { issue in
              Button {
                model.selectedIssueID = issue.id
                openQueue()
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
          openQueue()
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
  /// Counted exactly like the queue sidebar, so both always show the same numbers.
  private func count(_ filter: QueueFilter) -> Int {
    model.snapshot.issues.filter { filter.includes($0) }.count
  }
  /// The reports behind the selected count, newest first.
  private var listed: [Issue] { model.snapshot.issues.filter { list.includes($0) }.reversed() }
  /// The queue opens on the list shown here, so a row is never opened beside another list.
  private func openQueue() {
    model.queueFilterRequest = list
    model.queueAction?()
  }
  func metric(_ title: String, _ value: Int, list item: QueueFilter, phrase: String) -> some View {
    Button {
      list = item
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(value, format: .number).font(.system(size: 24, weight: .semibold, design: .rounded))
          .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
        Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
      }
      .padding(.horizontal, 8).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(list == item ? Color.primary.opacity(0.1) : Color.clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: phrase))
    .accessibilityAddTraits(list == item ? [.isButton, .isSelected] : .isButton)
  }
}
