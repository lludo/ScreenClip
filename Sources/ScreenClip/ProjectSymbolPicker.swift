import AppKit
import ScreenClipCore
import SwiftUI

/// A button showing the project's SF Symbol that opens a searchable grid of symbols.
struct ProjectSymbolPicker: View {
  @Binding var symbol: String?
  @State private var isPresented = false
  var body: some View {
    LabeledContent("Icon") {
      Button {
        isPresented = true
      } label: {
        Image(systemName: symbol ?? Project.defaultSymbol)
          .font(.system(size: 15))
          .foregroundStyle(.orange)
          .frame(width: 28, height: 22)
      }
      .help("Choose an icon for this project")
      .accessibilityLabel("Project icon")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        SymbolGrid(selection: $symbol) { isPresented = false }
      }
    }
  }
}

private struct SymbolGrid: View {
  @Binding var selection: String?
  var onPick: () -> Void
  @State private var query = ""
  private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

  /// Matches the curated list by name, and also offers the typed text when it names any valid
  /// SF Symbol, so people can use symbols outside the list.
  private var results: [String] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return Self.symbols }
    var matches = Self.symbols.filter { $0.contains(needle) }
    if !matches.contains(needle), NSImage(systemSymbolName: needle, accessibilityDescription: nil) != nil {
      matches.insert(needle, at: 0)
    }
    return matches
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField("Search or type a symbol name", text: $query)
        .textFieldStyle(.roundedBorder)
      ScrollView {
        if results.isEmpty {
          Text("No matching symbols.").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
        } else {
          LazyVGrid(columns: columns, spacing: 6) {
            ForEach(results, id: \.self) { name in
              let selected = (selection ?? Project.defaultSymbol) == name
              Button {
                selection = name == Project.defaultSymbol ? nil : name
                onPick()
              } label: {
                Image(systemName: name)
                  .font(.system(size: 15))
                  .frame(width: 34, height: 30)
                  .foregroundStyle(selected ? Color.white : Color.primary)
                  .background(
                    selected ? Color.orange : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                  .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .help(name)
              .accessibilityLabel(name)
            }
          }
        }
      }.frame(height: 230)
    }
    .padding(12)
    .frame(width: 8 * 34 + 7 * 6 + 24)
  }

  static let symbols: [String] = [
    "folder", "folder.fill", "tray.full", "archivebox", "doc.text", "book", "books.vertical",
    "bookmark", "tag", "paperclip", "link", "globe", "network", "server.rack", "externaldrive",
    "cloud", "icloud", "bolt", "bolt.fill", "flame", "sparkles", "star", "star.fill", "heart",
    "heart.fill", "leaf", "drop", "sun.max", "moon", "snowflake", "camera", "photo", "film",
    "music.note", "mic", "headphones", "gamecontroller", "paintbrush", "paintpalette", "pencil",
    "scissors", "hammer", "wrench.and.screwdriver", "gearshape", "gearshape.2", "cpu", "memorychip",
    "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces", "function", "cube",
    "cube.box", "shippingbox", "puzzlepiece", "square.stack.3d.up", "square.grid.2x2",
    "rectangle.3.group", "macwindow", "menubar.rectangle", "laptopcomputer", "desktopcomputer",
    "iphone", "ipad", "applewatch", "tv", "display", "keyboard", "printer", "app", "app.badge",
    "safari", "envelope", "message", "bubble.left.and.bubble.right", "phone", "video", "bell",
    "calendar", "clock", "alarm", "timer", "chart.bar", "chart.pie", "chart.line.uptrend.xyaxis",
    "list.bullet", "checklist", "checkmark.seal", "flag", "map", "location", "house", "building.2",
    "storefront", "cart", "bag", "creditcard", "banknote", "dollarsign.circle", "gift", "person",
    "person.2", "person.3", "figure.walk", "graduationcap", "briefcase", "lock", "key", "shield",
    "eye", "magnifyingglass", "lightbulb", "brain", "atom", "testtube.2", "cross.case", "pills",
    "pawprint", "ant", "ladybug", "tortoise", "hare", "bird", "fish", "car", "airplane", "bicycle",
    "tram", "ferry", "fork.knife", "cup.and.saucer", "wineglass", "birthday.cake", "trophy",
    "medal", "crown", "theatermasks", "face.smiling", "hand.thumbsup", "circle.hexagongrid",
    "triangle", "square", "circle", "diamond", "hexagon", "seal", "a.circle", "b.circle",
    "c.circle", "1.circle", "2.circle", "3.circle",
  ]
}
