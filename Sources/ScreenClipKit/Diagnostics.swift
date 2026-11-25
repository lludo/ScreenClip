#if os(iOS) && DEBUG
  import Darwin
  import Foundation
  import Network
  import OSLog
  import ScreenClipWire
  import UIKit

  /// Optional files sent with a report. Everything here is read from the app's own process, needs
  /// no permission, and takes well under a second. Agents read these only when they need them.
  enum Diagnostics {
    static let logWindow: TimeInterval = 120
    static let logLineLimit = 500
    static let maximumFileBytes = 400 * 1024

    // MARK: Logs

    /// The app's own unified-log entries from the last two minutes. System frameworks are noisy,
    /// so `com.apple.*` entries are kept only at error or fault level.
    static func recentLogs(until end: Date) -> DiagnosticFile? {
      let started = Date()
      defer { kitLog.debug("Read logs in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s") }
      guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
        let entries = try? store.getEntries(at: store.position(date: end.addingTimeInterval(-logWindow)))
      else { return nil }
      let formatter = DateFormatter()
      formatter.dateFormat = "HH:mm:ss.SSS"
      var lines: [String] = []
      var repeats = 0
      for case let entry as OSLogEntryLog in entries {
        guard entry.date <= end, entry.subsystem != kitSubsystem else { continue }
        if entry.subsystem.hasPrefix("com.apple."), entry.level != .error, entry.level != .fault { continue }
        let origin = entry.subsystem.isEmpty ? entry.process : "\(entry.subsystem)/\(entry.category)"
        var line = "\(formatter.string(from: entry.date)) \(levelName(entry.level)) [\(origin)] \(entry.composedMessage)"
        if line.count > 600 { line = String(line.prefix(600)) + "…" }
        // Frameworks repeat themselves; one line with a count reads better than fifty.
        let body = line.drop(while: { $0 != " " })
        if let last = lines.last, last.drop(while: { $0 != " " }).hasPrefix(body) {
          repeats += 1
          continue
        }
        if repeats > 0 { lines[lines.count - 1] += "  (repeated \(repeats + 1)×)" }
        repeats = 0
        lines.append(line)
        if lines.count > logLineLimit * 2 { lines.removeFirst(lines.count - logLineLimit) }
      }
      if repeats > 0, !lines.isEmpty { lines[lines.count - 1] += "  (repeated \(repeats + 1)×)" }
      if lines.count > logLineLimit { lines.removeFirst(lines.count - logLineLimit) }
      guard !lines.isEmpty else { return nil }
      return DiagnosticFile(
        name: "logs.txt", summary: "\(lines.count) app log lines from the 2 minutes before the capture",
        data: capped(lines.joined(separator: "\n")))
    }

    static func levelName(_ level: OSLogEntryLog.Level) -> String {
      switch level {
      case .debug: return "debug"
      case .info: return "info"
      case .notice: return "notice"
      case .error: return "ERROR"
      case .fault: return "FAULT"
      default: return "log"
      }
    }

    static func capped(_ text: String) -> Data {
      var data = Data(text.utf8)
      if data.count > maximumFileBytes {
        // Keep the end: the moments right before the capture matter most.
        data = Data("…\n".utf8) + data.suffix(maximumFileBytes)
      }
      return data
    }

    // MARK: View tree

    /// SwiftUI vends its accessibility elements only while app accessibility is on, the switch
    /// UI tests and Accessibility Inspector use. It is a device-wide setting, so it is turned on
    /// only for the moment the tree is read, and only if it was off.
    enum AppAccessibility {
      typealias Getter = @convention(c) () -> Bool
      typealias Setter = @convention(c) (Bool) -> Void
      static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
      static let getter = library.flatMap { dlsym($0, "_AXSApplicationAccessibilityEnabled") }
        .map { unsafeBitCast($0, to: Getter.self) }
      static let setter = library.flatMap { dlsym($0, "_AXSApplicationAccessibilitySetEnabled") }
        .map { unsafeBitCast($0, to: Setter.self) }

      /// Turns it on if needed. Returns true when it was off, so the caller waits a moment for
      /// SwiftUI and calls `restore()` afterwards.
      static func enableTemporarily() -> Bool {
        guard let getter, let setter, !getter() else { return false }
        setter(true)
        return true
      }
      static func restore() { setter?(false) }
    }

    struct Node: Encodable {
      var type: String
      var id: String?
      var label: String?
      var value: String?
      var traits: [String]?
      var frame: [Int]
      var hidden: Bool?
      var disabled: Bool?
      var children: [Node]?
    }

    /// The captured window's views and accessibility elements (SwiftUI content appears as
    /// accessibility elements), with identifiers, labels, and frames in points.
    @MainActor static func viewTree(of window: UIWindow) -> DiagnosticFile? {
      var budget = 2000
      let root = node(for: window, in: window, depth: 0, budget: &budget)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      guard let data = try? encoder.encode(root) else { return nil }
      return DiagnosticFile(
        name: "view-tree.json",
        summary: "views and accessibility elements on screen, with identifiers, labels, and frames (\(2000 - budget) nodes)",
        data: data)
    }

    @MainActor static func node(for view: UIView, in window: UIWindow, depth: Int, budget: inout Int) -> Node {
      budget -= 1
      let frame = view.convert(view.bounds, to: window)
      var node = Node(
        type: String(describing: type(of: view)).components(separatedBy: "<").first ?? "UIView",
        id: nonEmpty(view.accessibilityIdentifier),
        label: nonEmpty(view.isAccessibilityElement ? view.accessibilityLabel : nil),
        value: nonEmpty(view.isAccessibilityElement ? view.accessibilityValue : nil),
        traits: view.isAccessibilityElement ? traitNames(view.accessibilityTraits) : nil,
        frame: rounded(frame), hidden: view.isHidden || view.alpha < 0.01 ? true : nil,
        disabled: (view as? UIControl).map { $0.isEnabled ? nil : true } ?? nil)
      guard node.hidden == nil, depth < 60, budget > 0 else { return node }
      var children: [Node] = []
      for subview in view.subviews where budget > 0 {
        children.append(Self.node(for: subview, in: window, depth: depth + 1, budget: &budget))
      }
      children += elements(of: view, depth: depth + 1, budget: &budget)
      node.children = children.isEmpty ? nil : children
      return node
    }

    /// Accessibility elements a view vends without being views, as SwiftUI hosting views do.
    @MainActor static func elements(of container: NSObject, depth: Int, budget: inout Int) -> [Node] {
      let count = container.accessibilityElementCount()
      guard count != NSNotFound, count > 0, depth < 60 else { return [] }
      var nodes: [Node] = []
      for index in 0..<min(count, 400) where budget > 0 {
        guard let element = container.accessibilityElement(at: index) as? NSObject, !(element is UIView) else {
          continue
        }
        budget -= 1
        var node = Node(
          type: "AccessibilityElement",
          id: nonEmpty(identifier(of: element)),
          label: nonEmpty(element.accessibilityLabel), value: nonEmpty(element.accessibilityValue),
          traits: traitNames(element.accessibilityTraits), frame: rounded(element.accessibilityFrame))
        let children = elements(of: element, depth: depth + 1, budget: &budget)
        node.children = children.isEmpty ? nil : children
        nodes.append(node)
      }
      return nodes
    }

    /// SwiftUI's elements answer `accessibilityIdentifier` without declaring the protocol.
    static func identifier(of element: NSObject) -> String? {
      if let identified = element as? UIAccessibilityIdentification { return identified.accessibilityIdentifier }
      let selector = NSSelectorFromString("accessibilityIdentifier")
      guard element.responds(to: selector) else { return nil }
      return element.perform(selector)?.takeUnretainedValue() as? String
    }

    static func traitNames(_ traits: UIAccessibilityTraits) -> [String]? {
      let known: [(UIAccessibilityTraits, String)] = [
        (.button, "button"), (.link, "link"), (.header, "header"), (.image, "image"),
        (.staticText, "text"), (.selected, "selected"), (.notEnabled, "disabled"),
        (.adjustable, "adjustable"), (.searchField, "searchField"), (.tabBar, "tabBar"),
        (.keyboardKey, "key"), (.updatesFrequently, "updatesFrequently"),
      ]
      let names = known.filter { traits.contains($0.0) }.map(\.1)
      return names.isEmpty ? nil : names
    }

    static func rounded(_ rect: CGRect) -> [Int] {
      guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else {
        return [0, 0, 0, 0]
      }
      return [Int(rect.minX.rounded()), Int(rect.minY.rounded()), Int(rect.width.rounded()), Int(rect.height.rounded())]
    }

    static func nonEmpty(_ text: String?) -> String? {
      guard let text, !text.isEmpty else { return nil }
      return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    // MARK: Device state

    @MainActor static func deviceState(scene: UIWindowScene, startedAt: Date) -> DiagnosticFile? {
      let device = UIDevice.current
      let wasMonitoring = device.isBatteryMonitoringEnabled
      device.isBatteryMonitoringEnabled = true
      defer { device.isBatteryMonitoringEnabled = wasMonitoring }
      let traits = scene.traitCollection
      var state: [String: String] = [
        "memoryFootprintMB": memoryFootprint().map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "unknown",
        "cpuPercent": cpuUsage().map { String(format: "%.0f", $0) } ?? "unknown",
        "thermalState": thermalName(ProcessInfo.processInfo.thermalState),
        "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
        "batteryLevel": device.batteryLevel < 0 ? "unknown" : String(format: "%.0f%%", device.batteryLevel * 100),
        "batteryState": batteryName(device.batteryState),
        "secondsSinceScreenClipStart": String(Int(Date().timeIntervalSince(startedAt))),
        "applicationState": applicationStateName(UIApplication.shared.applicationState),
        "network": NetworkWatcher.shared.summary,
        "colorScheme": traits.userInterfaceStyle == .dark ? "dark" : "light",
        "dynamicType": traits.preferredContentSizeCategory.rawValue,
        "layoutDirection": traits.layoutDirection == .rightToLeft ? "rightToLeft" : "leftToRight",
        "horizontalSizeClass": traits.horizontalSizeClass == .compact ? "compact" : "regular",
        "reduceMotion": String(UIAccessibility.isReduceMotionEnabled),
        "boldText": String(UIAccessibility.isBoldTextEnabled),
        "increaseContrast": String(UIAccessibility.isDarkerSystemColorsEnabled),
        "voiceOver": String(UIAccessibility.isVoiceOverRunning),
        "timeZone": TimeZone.current.identifier,
        "preferredLanguages": Locale.preferredLanguages.prefix(3).joined(separator: ", "),
      ]
      if let free = freeDiskBytes() { state["freeDiskGB"] = String(format: "%.1f", Double(free) / 1_000_000_000) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard let data = try? encoder.encode(state) else { return nil }
      return DiagnosticFile(
        name: "device-state.json",
        summary: "memory, CPU, thermal, battery, network, and display and accessibility settings", data: data)
    }

    static func memoryFootprint() -> UInt64? {
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func cpuUsage() -> Double? {
      var threads: thread_act_array_t?
      var count: mach_msg_type_number_t = 0
      guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
      defer {
        vm_deallocate(
          mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
      }
      var total = 0.0
      for index in 0..<Int(count) {
        var info = thread_basic_info()
        var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
        let result = withUnsafeMutablePointer(to: &info) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
            thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
          }
        }
        if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
          total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
      }
      return total
    }

    static func freeDiskBytes() -> Int64? {
      let values = try? URL(fileURLWithPath: NSHomeDirectory())
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values?.volumeAvailableCapacityForImportantUsage
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
      switch state {
      case .nominal: return "nominal"
      case .fair: return "fair"
      case .serious: return "serious"
      case .critical: return "critical"
      @unknown default: return "unknown"
      }
    }

    static func batteryName(_ state: UIDevice.BatteryState) -> String {
      switch state {
      case .charging: return "charging"
      case .full: return "full"
      case .unplugged: return "unplugged"
      default: return "unknown"
      }
    }

    static func applicationStateName(_ state: UIApplication.State) -> String {
      switch state {
      case .active: return "active"
      case .inactive: return "inactive"
      case .background: return "background"
      @unknown default: return "unknown"
      }
    }
  }

  /// The current network path, kept up to date from `ScreenClipKit.start()`.
  final class NetworkWatcher: @unchecked Sendable {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var path: NWPath?

    func start() {
      monitor.pathUpdateHandler = { [weak self] path in
        guard let self else { return }
        self.lock.lock()
        self.path = path
        self.lock.unlock()
      }
      monitor.start(queue: DispatchQueue(label: "ScreenClipKit.network"))
    }

    var summary: String {
      lock.lock()
      defer { lock.unlock() }
      guard let path else { return "unknown" }
      guard path.status == .satisfied else { return "offline" }
      let interface: String =
        path.usesInterfaceType(.wifi) ? "wifi"
        : path.usesInterfaceType(.cellular) ? "cellular"
        : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
      var flags: [String] = []
      if path.isExpensive { flags.append("expensive") }
      if path.isConstrained { flags.append("lowDataMode") }
      return ([interface] + flags).joined(separator: ", ")
    }
  }

  /// Keeps the last lines written to stdout and stderr (`print`), still passing them through to
  /// Xcode's console. Off unless `ScreenClipOptions.captureConsoleOutput` is set.
  final class ConsoleCapture: @unchecked Sendable {
    static let shared = ConsoleCapture()
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""
    private var started = false
    private var pipes: [Pipe] = []
    static let lineLimit = 300

    func start() {
      lock.lock()
      defer { lock.unlock() }
      guard !started else { return }
      started = true
      setvbuf(stdout, nil, _IOLBF, 0)
      setvbuf(stderr, nil, _IONBF, 0)
      for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
        let original = dup(descriptor)
        guard original >= 0 else { continue }
        let pipe = Pipe()
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, descriptor) >= 0 else { continue }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          data.withUnsafeBytes { buffer in _ = write(original, buffer.baseAddress, buffer.count) }
          self?.append(data)
        }
        pipes.append(pipe)
      }
    }

    private func append(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      partial += String(decoding: data, as: UTF8.self)
      var pieces = partial.components(separatedBy: "\n")
      partial = pieces.removeLast()
      lines += pieces.map { $0.count > 600 ? String($0.prefix(600)) + "…" : $0 }
      if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
    }

    func file() -> DiagnosticFile? {
      lock.lock()
      defer { lock.unlock() }
      guard started else { return nil }
      let all = lines + (partial.isEmpty ? [] : [partial])
      guard !all.isEmpty else { return nil }
      return DiagnosticFile(
        name: "console.txt", summary: "last \(all.count) lines printed to stdout and stderr",
        data: Diagnostics.capped(all.joined(separator: "\n")))
    }
  }
#endif
