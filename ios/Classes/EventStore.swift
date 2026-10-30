import Foundation
import Flutter
import SQLite3

final class EventStore {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init() throws {
    let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    guard sqlite3_open(dir.appendingPathComponent("bluetooth_companion.db").path, &db) == SQLITE_OK else { throw error() }
    try execute("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, device_id TEXT NOT NULL, service TEXT, characteristic TEXT, received_at INTEGER NOT NULL, value BLOB, name TEXT, rssi INTEGER, motion TEXT NOT NULL)")
  }
  deinit { sqlite3_close(db) }
  private func error() -> NSError { NSError(domain: "BluetoothCompanionStorage", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
  private func execute(_ sql: String) throws { if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw error() } }
  func append(kind: String, device: String, service: String? = nil, characteristic: String? = nil, value: Data? = nil, name: String? = nil, rssi: Int? = nil) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "INSERT INTO events(kind,device_id,service,characteristic,received_at,value,name,rssi,motion) VALUES(?,?,?,?,?,?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw error() }
    defer { sqlite3_finalize(statement) }
    func bind(_ text: String?, _ index: Int32) { if let text = text { sqlite3_bind_text(statement, index, text, -1, transient) } else { sqlite3_bind_null(statement, index) } }
    bind(kind, 1); bind(device, 2); bind(service, 3); bind(characteristic, 4)
    sqlite3_bind_int64(statement, 5, Int64(Date().timeIntervalSince1970 * 1000))
    if let value = value { _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, 6, $0.baseAddress, Int32(value.count), transient) } } else { sqlite3_bind_null(statement, 6) }
    bind(name, 7); if let rssi = rssi { sqlite3_bind_int64(statement, 8, Int64(rssi)) } else { sqlite3_bind_null(statement, 8) }; bind("unknown", 9)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
  }
  func query(after: Int64, limit: Int) throws -> [[String: Any]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT id,kind,device_id,service,characteristic,received_at,value,name,rssi,motion FROM events WHERE id > ? ORDER BY id LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw error() }
    defer { sqlite3_finalize(statement) }; sqlite3_bind_int64(statement, 1, after); sqlite3_bind_int(statement, 2, Int32(limit))
    func text(_ i: Int32) -> Any { guard let p = sqlite3_column_text(statement, i) else { return NSNull() }; return String(cString: p) }
    var rows: [[String: Any]] = []
    while true {
      let status = sqlite3_step(statement); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw error() }
      let size = Int(sqlite3_column_bytes(statement, 6)); let bytes = sqlite3_column_blob(statement, 6)
      let value: Any = sqlite3_column_type(statement, 6) == SQLITE_NULL ? NSNull() : FlutterStandardTypedData(bytes: bytes.map { Data(bytes: $0, count: size) } ?? Data())
      rows.append(["id": sqlite3_column_int64(statement, 0), "kind": text(1), "deviceId": text(2), "service": text(3), "characteristic": text(4), "receivedAt": sqlite3_column_int64(statement, 5), "value": value, "name": text(7), "rssi": sqlite3_column_type(statement, 8) == SQLITE_NULL ? NSNull() : NSNumber(value: sqlite3_column_int(statement, 8)), "motion": text(9)])
    }
    return rows
  }
  func clear() throws -> Int { try execute("DELETE FROM events"); return Int(sqlite3_changes(db)) }
}
