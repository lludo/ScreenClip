import ScreenClipCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct ShortcutRecorder: NSViewRepresentable {
  @Binding var settings: AppSettings
  func makeNSView(context: Context) -> RecorderField {
    let field = RecorderField()
    field.isEditable = false
    field.isSelectable = false
    field.isBezeled = true
    field.alignment = .center
    field.focusRingType = .exterior
    return field
  }
  func updateNSView(_ field: RecorderField, context: Context) {
    field.stringValue = settings.shortcutDescription
    field.record = { key, modifiers, label in
      settings.shortcutKey = key
      settings.shortcutModifiers = modifiers
      settings.shortcutDescription = label
    }
  }
}
final class RecorderField: NSTextField {
  var record: ((UInt32, UInt32, String) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    stringValue = "Press shortcut…"
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
      stringValue = "Include ⌘, ⌃ or ⌥"
      return
    }
    var value: UInt32 = 0
    var label = ""
    if flags.contains(.control) {
      value |= 4096
      label += "⌃"
    }
    if flags.contains(.option) {
      value |= 2048
      label += "⌥"
    }
    if flags.contains(.shift) {
      value |= 512
      label += "⇧"
    }
    if flags.contains(.command) {
      value |= 256
      label += "⌘"
    }
    label += event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    record?(UInt32(event.keyCode), value, label)
    stringValue = label
    window?.makeFirstResponder(nil)
  }
}
