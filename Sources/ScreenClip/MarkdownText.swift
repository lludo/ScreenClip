import SwiftUI

/// Agent summaries are Markdown. Foundation parses it natively, but SwiftUI `Text` only styles
/// inline runs (bold, code, links), so the blocks (headings, lists, quotes, code) are laid out here.
struct MarkdownText: View {
  let blocks: [Block]

  init(_ markdown: String) {
    // The detail view re-renders on every queue change; parse each summary once.
    if let cached = Self.cache.object(forKey: markdown as NSString) {
      blocks = cached.blocks
    } else {
      blocks = Self.blocks(markdown)
      Self.cache.setObject(Cached(blocks), forKey: markdown as NSString)
    }
  }

  private final class Cached {
    let blocks: [Block]
    init(_ blocks: [Block]) { self.blocks = blocks }
  }
  private nonisolated(unsafe) static let cache: NSCache<NSString, Cached> = {
    let cache = NSCache<NSString, Cached>()
    cache.countLimit = 64
    return cache
  }()

  struct Block: Equatable {
    enum Kind: Equatable { case paragraph, heading(Int), code, rule, tableRow(header: Bool) }
    var kind: Kind
    var text: AttributedString
    /// "•" or "3." on the first block of a list item, otherwise empty.
    var marker = ""
    var depth = 0
    var quoted = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        row(block).padding(.leading, CGFloat(block.depth) * 18)
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func row(_ block: Block) -> some View {
    let content = HStack(alignment: .firstTextBaseline, spacing: 6) {
      if !block.marker.isEmpty {
        Text(verbatim: block.marker).monospacedDigit().foregroundStyle(.secondary)
          .frame(minWidth: 12, alignment: .trailing)
      }
      blockText(block)
    }
    if block.quoted {
      content.padding(.leading, 10).overlay(alignment: .leading) {
        Rectangle().fill(.tertiary).frame(width: 3)
      }.foregroundStyle(.secondary)
    } else {
      content
    }
  }

  @ViewBuilder private func blockText(_ block: Block) -> some View {
    switch block.kind {
    case .rule:
      Divider().padding(.vertical, 4)
    case .code:
      Text(block.text).font(.system(.callout, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    case .heading(let level):
      Text(block.text)
        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    case .tableRow(let header):
      Text(block.text).fontWeight(header ? .semibold : nil)
        .fixedSize(horizontal: false, vertical: true)
    case .paragraph:
      Text(block.text).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Agents write one item per line ("Changed:\nA.swift\nB.swift"). Markdown would join those
  /// lines into one; a hard break at the end of each line outside code fences keeps them.
  static func keepingLineBreaks(_ markdown: String) -> String {
    var fence: Substring?
    return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      let trimmed = line.drop(while: { $0 == " " })
      let marker = trimmed.prefix(3)
      if marker == "```" || marker == "~~~" {
        if fence == nil { fence = marker } else if fence == marker { fence = nil }
        return String(line)
      }
      guard fence == nil, !trimmed.isEmpty else { return String(line) }
      return line + "  "
    }.joined(separator: "\n")
  }

  static func blocks(_ markdown: String) -> [Block] {
    guard
      let parsed = try? AttributedString(
        markdown: keepingLineBreaks(markdown),
        options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return [Block(kind: .paragraph, text: AttributedString(markdown))] }
    var blocks: [Block] = []
    var markedItems: Set<Int> = []
    var lastRow: Int?
    for (intent, range) in parsed.runs[\.presentationIntent] {
      var block = Block(kind: .paragraph, text: AttributedString(parsed[range]))
      var row: Int?
      // Components run from the innermost block outwards, so a list item's list follows it.
      let components = intent?.components ?? []
      for (index, component) in components.enumerated() {
        switch component.kind {
        case .header(let level): block.kind = .heading(level)
        case .codeBlock:
          block.kind = .code
          if block.text.characters.last == "\n" { block.text.characters.removeLast() }
        case .thematicBreak: block.kind = .rule
        case .blockQuote: block.quoted = true
        case .listItem(let ordinal):
          // An item's later paragraphs and nested lists sit under its marker.
          if block.marker.isEmpty, markedItems.insert(component.identity).inserted {
            let ordered = components.dropFirst(index + 1).first?.kind == .orderedList
            block.marker = ordered ? "\(ordinal)." : "•"
          }
        case .orderedList, .unorderedList: block.depth += 1
        case .tableHeaderRow:
          block.kind = .tableRow(header: true)
          row = component.identity
        case .tableRow:
          block.kind = .tableRow(header: false)
          row = component.identity
        default: break
        }
      }
      block.depth = max(0, block.depth - 1)
      // Each table cell is its own run; show a row's cells on one line.
      if let row, row == lastRow, var previous = blocks.popLast() {
        previous.text += AttributedString("   ·   ") + block.text
        blocks.append(previous)
      } else {
        blocks.append(block)
      }
      lastRow = row
    }
    return blocks
  }
}
