import CSQLite
import Foundation

public enum ScreenClipError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    switch self {
    case .message(let text): return text
    }
  }
}

/// A single-writer durable store. SQLite commits the issue, input revision, and pending dispatch together.
public final class IssueStore {
  public let root: URL
  private var db: OpaquePointer?
  private var ownerFD: Int32 = -1
  private let readOnly: Bool
  private let lock = NSRecursiveLock()
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
    guard sqlite3_step(stmt) == SQLITE_ROW else { return StoreSnapshot() }
    let data = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
    let snapshot = try JSONDecoder().decode(StoreSnapshot.self, from: data)
    guard snapshot.version == 1 else {
      throw ScreenClipError.message(
        "This queue was created by a newer ScreenClip. Update the app before opening it.")
    }
    return snapshot
  }
  public func save(_ snapshot: StoreSnapshot) throws {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    lock.lock()
    defer { lock.unlock() }
    let data = try JSONEncoder().encode(snapshot)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard
      sqlite3_prepare_v2(
        db,
        "INSERT INTO state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
        -1, &stmt, nil) == SQLITE_OK
    else { throw ScreenClipError.message("Cannot prepare queue save.") }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    _ = data.withUnsafeBytes {
      sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(data.count), transient)
    }
    guard sqlite3_step(stmt) == SQLITE_DONE else {
      throw ScreenClipError.message(
        "Could not save the report: \(String(cString: sqlite3_errmsg(db)))")
    }
  }
  public func writeAsset(_ data: Data, original: Bool = false) throws -> String {
    guard !readOnly else { throw ScreenClipError.message("This queue connection is read-only.") }
    let path = root.appendingPathComponent(original ? "originals" : "assets")
      .appendingPathComponent(UUID().uuidString + ".png")
    try data.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    return path.path
  }
  public func export(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let snapshot = try load()
    var exported = snapshot
    for i in exported.issues.indices {
      for c in exported.issues[i].captures.indices {
        let source = URL(fileURLWithPath: exported.issues[i].captures[c].imagePath)
        let filename = source.lastPathComponent
        let destination = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.copyItem(at: source, to: destination)
        }
        exported.issues[i].captures[c].imagePath = filename
        exported.issues[i].captures[c].originalPath = nil
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(exported).write(
      to: directory.appendingPathComponent("screenclip-export.json"), options: .atomic)
  }
  public func deleteAssets(for issue: Issue) throws {
    for capture in issue.captures {
      for name in [capture.imagePath, capture.originalPath].compactMap({ $0 }) {
        let url = URL(fileURLWithPath: name).standardizedFileURL
        guard
          url.path.hasPrefix(root.standardizedFileURL.path + "/assets/")
            || url.path.hasPrefix(root.standardizedFileURL.path + "/originals/")
        else { continue }
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      }
    }
  }
}
