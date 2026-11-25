import CSQLite
import Foundation

/// A single-writer durable store. SQLite commits the issue, input revision, and pending dispatch together.
public final class IssueStore {
  public let root: URL
  private var db: OpaquePointer?
  private var ownerFD: Int32 = -1
  private let readOnly: Bool
  private let lock = NSRecursiveLock()
  /// The last snapshot this writer loaded or saved. The writer lock makes this connection the
  /// only writer, so save() reuses it instead of reading and decoding the whole queue again.
  private var cached: StoreSnapshot?
  public init(root: URL, readOnly: Bool = false) throws {
    self.root = root
    self.readOnly = readOnly
    if !readOnly {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for name in ["assets", "originals", "worktrees", "runs"] {
        try FileManager.default.createDirectory(
          at: root.appendingPathComponent(name), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
      ownerFD = open(
        root.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
      guard ownerFD >= 0, flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else {
        if ownerFD >= 0 {
          close(ownerFD)
          ownerFD = -1
        }
        throw ScreenClipError.message(
          "ScreenClip is already using this queue. Open the running instance from the menu bar.")
      }
    }
    guard
      sqlite3_open_v2(
        root.appendingPathComponent("screenclip.sqlite").path, &db,
        (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
          | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else { throw ScreenClipError.message("Could not open the local queue database.") }
    sqlite3_busy_timeout(db, 5000)
    if !readOnly {
      try execute(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
      )
      _ = chmod(root.appendingPathComponent("screenclip.sqlite").path, 0o600)
    }
  }
  deinit {
    sqlite3_close(db)
    if ownerFD >= 0 { close(ownerFD) }
  }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw ScreenClipError.message(String(cString: sqlite3_errmsg(db)))
    }
  }
  public func load() throws -> StoreSnapshot {
    lock.lock()
    defer { lock.unlock() }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard
      sqlite3_prepare_v2(db, "SELECT payload FROM state WHERE id=1", -1, &stmt, nil) == SQLITE_OK
    else { throw ScreenClipError.message("Cannot read the queue.") }
    let result = sqlite3_step(stmt)
    guard result == SQLITE_ROW || result == SQLITE_DONE else {
      throw ScreenClipError.message("Cannot read the queue.")
    }
    guard result == SQLITE_ROW else { return StoreSnapshot() }
    let length = Int(sqlite3_column_bytes(stmt, 0))
    // A zero-length blob has a nil pointer; treat it as an empty queue instead of crashing.
    guard length > 0, let bytes = sqlite3_column_blob(stmt, 0) else { return StoreSnapshot() }
    let data = Data(bytes: bytes, count: length)
    struct Header: Decodable {
      var version: Int
      var minimumReaderVersion: Int?
    }
    // Check the format before decoding it, so a newer queue gets the friendly message.
    if let header = try? JSONDecoder().decode(Header.self, from: data),
      header.version > 1 || (header.minimumReaderVersion ?? 1) > StoreSnapshot.readerVersion
    {
      throw ScreenClipError.message(
        "This queue was created by a newer ScreenClip. Update the app before opening it.")
    }
    var snapshot = try JSONDecoder().decode(StoreSnapshot.self, from: data)
    guard snapshot.version == 1 else {
      throw ScreenClipError.message(
        "This queue was created by a newer ScreenClip. Update the app before opening it.")
    }
    snapshot.assignReportNumbers()
    if !readOnly { cached = snapshot }
    return snapshot
  }
  @discardableResult public func save(_ snapshot: StoreSnapshot) throws -> StoreSnapshot {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    lock.lock()
    defer { lock.unlock() }
    var numbered = snapshot
    let previous = try cached ?? load()
    // Tolerate a damaged snapshot with repeated IDs instead of trapping on every save.
    let existingNumbers = Dictionary(
      previous.issues.compactMap { issue in
        issue.reportNumber.map { (issue.id, $0) }
      }, uniquingKeysWith: { first, _ in first })
    for index in numbered.issues.indices {
      if let number = existingNumbers[numbered.issues[index].id] {
        numbered.issues[index].reportNumber = number
      }
    }
    numbered.assignReportNumbers(startingAt: previous.nextReportNumber ?? 1)
    let data = try JSONEncoder().encode(numbered)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard
      sqlite3_prepare_v2(
        db,
        "INSERT INTO state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
        -1, &stmt, nil) == SQLITE_OK
    else { throw ScreenClipError.message("Cannot prepare queue save.") }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bound = data.withUnsafeBytes {
      sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient)
    }
    guard bound == SQLITE_OK else { throw ScreenClipError.message("Cannot prepare queue save.") }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw ScreenClipError.message(
        "Could not save the report: \(String(cString: sqlite3_errmsg(db)))")
    }
    cached = numbered
    return numbered
  }
  public func writeAsset(_ data: Data, original: Bool = false) throws -> String {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    let path = root.appendingPathComponent(original ? "originals" : "assets")
      .appendingPathComponent(UUID().uuidString + ".png")
    do {
      try data.write(to: path, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    } catch {
      try? FileManager.default.removeItem(at: path)
      throw error
    }
    return path.path
  }
  /// Writes diagnostic files into a new folder under `diagnostics/`. Names must already be plain
  /// file names. Returns the folder.
  public func writeDiagnostics(_ files: [(name: String, data: Data)]) throws -> String {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    let folder = root.appendingPathComponent("diagnostics").appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for file in files {
        guard !file.name.contains("/"), !file.name.hasPrefix(".") else { continue }
        let url = folder.appendingPathComponent(file.name)
        try file.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      }
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
    return folder.path
  }
  /// A copy of a diagnostics folder, so two reports never share files.
  public func copyDiagnostics(_ folder: String) throws -> String {
    let source = URL(fileURLWithPath: folder)
    let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
    return try writeDiagnostics(names.map { ($0, try Data(contentsOf: source.appendingPathComponent($0))) })
  }
  public func export(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let snapshot = try load()
    var exported = snapshot
    for i in exported.issues.indices {
      for c in exported.issues[i].captures.indices {
        exported.issues[i].captures[c].originalPath = nil
        exported.issues[i].captures[c].diagnostics = nil
        guard let path = exported.issues[i].captures[c].imagePath else { continue }
        let source = URL(fileURLWithPath: path)
        let filename = source.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        // A capture whose image is gone should not abort the whole export.
        if !FileManager.default.fileExists(atPath: destination.path),
          FileManager.default.fileExists(atPath: source.path)
        {
          try FileManager.default.copyItem(at: source, to: destination)
        }
        exported.issues[i].captures[c].imagePath = filename
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(exported).write(
      to: directory.appendingPathComponent("screenclip-export.json"), options: .atomic)
  }
  public func deleteAssets(for issue: Issue) throws {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    var firstFailure: Error?
    for capture in issue.captures {
      for name in [capture.imagePath, capture.originalPath].compactMap({ $0 }) {
        let url = URL(fileURLWithPath: name).standardizedFileURL
        guard
          url.path.hasPrefix(root.standardizedFileURL.path + "/assets/")
            || url.path.hasPrefix(root.standardizedFileURL.path + "/originals/")
        else { continue }
        if FileManager.default.fileExists(atPath: url.path) {
          // Keep going so one stuck file does not orphan the rest.
          do { try FileManager.default.removeItem(at: url) } catch { firstFailure = firstFailure ?? error }
        }
      }
      if let folder = capture.diagnostics?.folder {
        let url = URL(fileURLWithPath: folder).standardizedFileURL
        if url.path.hasPrefix(root.standardizedFileURL.path + "/diagnostics/"),
          FileManager.default.fileExists(atPath: url.path)
        {
          do { try FileManager.default.removeItem(at: url) } catch { firstFailure = firstFailure ?? error }
        }
      }
    }
    if let firstFailure { throw firstFailure }
  }
}
