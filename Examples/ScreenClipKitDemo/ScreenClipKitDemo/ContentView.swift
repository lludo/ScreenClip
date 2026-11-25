import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.example.ScreenClipKitDemo", category: "Menu")

#if DEBUG
  import ScreenClipKit
#endif

/// A small shop with a few screens, so reports carry a meaningful screen path.
struct ContentView: View {
  struct Item: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let price: String
    let symbol: String
  }
  private let items = [
    Item(name: "Espresso", price: "$3.00", symbol: "cup.and.saucer.fill"),
    Item(name: "Croissant", price: "$2.50", symbol: "birthday.cake.fill"),
    Item(name: "Orange juice", price: "$4.00", symbol: "drop.fill"),
  ]

  var body: some View {
    TabView {
      NavigationStack {
        List(items) { item in
          NavigationLink(value: item) {
            Label("\(item.name) — \(item.price)", systemImage: item.symbol)
          }
        }
        .navigationTitle("Menu")
        .navigationDestination(for: Item.self) { item in
          DetailView(item: item)
        }
      }
      .tabItem { Label("Menu", systemImage: "list.bullet") }

      NavigationStack {
        Form {
          Section("Report a problem") {
            Text("Shake the device, or take a screenshot, to report what you see.")
            #if DEBUG
              Button("Report this screen") { ScreenClipKit.capture() }
              Button("ScreenClip settings") { ScreenClipKit.showSettings() }
            #endif
          }
        }
        .navigationTitle("Settings")
      }
      .tabItem { Label("Settings", systemImage: "gearshape") }
    }
  }
}

struct DetailView: View {
  let item: ContentView.Item
  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: item.symbol).font(.system(size: 80)).foregroundStyle(.orange)
      Text(item.name).font(.largeTitle.bold())
      // A deliberately clipped button, something to report.
      Button("Add to order for \(item.price) and continue to checkout") {}
        .buttonStyle(.borderedProminent)
        .frame(width: 180)
        .lineLimit(1)
        .accessibilityIdentifier("detail.addToOrder")
    }
    .navigationTitle(item.name)
    .onAppear {
      log.info("Opened detail for \(item.name, privacy: .public)")
      print("DetailView appeared: \(item.name)")
    }
  }
}
