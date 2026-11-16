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
    stringValue = Chrome.text(
      "Press shortcut…", comment: "Shown while recording a keyboard shortcut.")
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      window?.makeFirstResponder(nil)
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
      stringValue = Chrome.text(
        "Include ⌘, ⌃ or ⌥", comment: "Shortcut must include Command, Control, or Option. Keep the symbols.")
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
    label += Self.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
    record?(UInt32(event.keyCode), value, label)
    stringValue = label
    window?.makeFirstResponder(nil)
  }
  /// Keys that type nothing visible (Space, arrows, function keys) get a readable name.
  static func keyLabel(keyCode: UInt16, characters: String?) -> String {
    let named: [UInt16: String] = [
      49: "Space", 36: "↩", 76: "⌅", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
      123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
      101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    if let name = named[keyCode] { return name }
    let typed = (characters ?? "").uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    // Function-area keys report private-use characters that draw as blanks or boxes.
    let printable = !typed.isEmpty && typed.unicodeScalars.allSatisfy {
      !(0xF700...0xF8FF).contains($0.value) && !CharacterSet.controlCharacters.contains($0)
    }
    return printable ? typed : "Key \(keyCode)"
  }
}
