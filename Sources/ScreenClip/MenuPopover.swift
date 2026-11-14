import AppKit
import ScreenClipCore
import SwiftUI
import UserNotifications

struct MenuPopover: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("ScreenClip", systemImage: "viewfinder").font(.headline)
        Spacer()
        if model.snapshot.settings.paused {
          Text("Paused").font(.caption).foregroundStyle(.secondary)
        }
        Button {
          model.settingsAction?()
        } label: {
          Image(systemName: "gearshape")
        }.buttonStyle(.plain)
      }
      HStack(spacing: 25) {
        metric("Open", model.snapshot.activeCount)
        metric("Needs you", model.snapshot.attentionCount)
        metric(
          "To retest", model.snapshot.issues.filter { $0.status == .merged && !$0.archived }.count)
      }
      Button {
        model.captureAction?()
      } label: {
        HStack {
          Label("New capture", systemImage: "plus")
          Spacer()
          Text(model.snapshot.settings.shortcutDescription).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
      }.buttonStyle(.borderedProminent).tint(.orange)
      // Banners raised outside the queue window (quit, relaunch, shortcut conflicts).
      if let banner = model.banner {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          Text(banner).font(.caption).lineLimit(4).textSelection(.enabled)
          Spacer()
          Button {
            model.banner = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
      }
      Divider()
      if model.snapshot.issues.isEmpty {
        Text("Your observations will appear here.").font(.callout).foregroundStyle(.secondary)
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
      HStack {
        Button("Open queue") { model.queueAction?() }
        Spacer()
        Button(model.snapshot.settings.paused ? "Resume" : "Pause") {
          model.togglePaused()
        }
        Menu {
          Button("Quit ScreenClip") { NSApp.terminate(nil) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("More options").help("More options")
      }
    }.padding(20).frame(width: 370)
  }
  func metric(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(value)").font(.system(size: 24, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }
  }
}
