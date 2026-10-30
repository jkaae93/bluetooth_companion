import Flutter
import UIKit
import CoreBluetooth

public class BluetoothCompanionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CBCentralManagerDelegate, CBPeripheralDelegate {
  private var central: CBCentralManager!
  private var sink: FlutterEventSink?
  private var peripherals: [String: CBPeripheral] = [:]
  private var pending: [String: FlutterResult] = [:]
  private var pendingTokens: [String: UUID] = [:]
  private var pendingRead: [String: CBCharacteristic] = [:]
  private var discovered: [String: [CBCharacteristic]] = [:]
  private var scanTimer: Timer?
  private var scanLocalName: String?
  private var store: EventStore?
  private var recordValues = false
  private var recordAdvertisements = false
  private func record(_ action: (EventStore) throws -> Void) {
    do { if store == nil { store = try EventStore() }; try action(store!) } catch { sink?(["type": "error", "code": "STORAGE_ERROR", "message": error.localizedDescription]) }
  }
  private let savedKey = "bluetooth_companion_saved_devices"

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BluetoothCompanionPlugin()
    let channel = FlutterMethodChannel(name: "bluetooth_companion/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "bluetooth_companion/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
    instance.central = CBCentralManager(delegate: instance, queue: nil)
  }
  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  private func fail(_ code: String, _ message: String) -> FlutterError { FlutterError(code: code, message: message, details: nil) }
  private func state() -> String {
    switch central.state { case .poweredOn: return "on"; case .poweredOff: return "off"; case .unauthorized: return "unauthorized"; case .unsupported: return "unsupported"; default: return "unknown" }
  }
  public func centralManagerDidUpdateState(_ central: CBCentralManager) { sink?(["type": "adapter", "state": state()]) }
  private func finish(_ id: String, _ value: Any? = nil) { pendingTokens.removeValue(forKey: id); pendingRead.removeValue(forKey: id); if let result = pending.removeValue(forKey: id) { result(value) } }
  private func begin(_ id: String, _ result: @escaping FlutterResult, _ action: () -> Void) {
    guard pending[id] == nil else { result(fail("BUSY", "A GATT operation is already pending for this device")); return }
    pending[id] = result
    let token = UUID(); pendingTokens[id] = token
    action()
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in guard let self = self, self.pendingTokens[id] == token else { return }; self.finish(id, self.fail("TIMEOUT", "Operation timed out")) }
  }
  private func peripheral(_ id: String) -> CBPeripheral? {
    if let p = peripherals[id] { return p }
    guard let uuid = UUID(uuidString: id), let p = central.retrievePeripherals(withIdentifiers: [uuid]).first else { return nil }
    peripherals[id] = p; p.delegate = self; return p
  }
  private func characteristic(_ p: CBPeripheral, _ args: [String: Any]) -> CBCharacteristic? {
    guard let service = args["service"] as? String, let uuid = args["characteristic"] as? String else { return nil }
    return p.services?.first(where: { $0.uuid == CBUUID(string: service) })?.characteristics?.first(where: { $0.uuid == CBUUID(string: uuid) })
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["deviceId"] as? String ?? ""
    switch call.method {
    case "dispose":
      scanTimer?.invalidate(); central.stopScan()
      for p in peripherals.values where p.state != .disconnected { central.cancelPeripheralConnection(p) }
      for key in Array(pending.keys) { finish(key, fail("DISPOSED", "Bluetooth disposed")) }
      peripherals.removeAll(); discovered.removeAll(); result(nil)
    case "configureRecording":
      do { if store == nil { store = try EventStore() }; recordValues = args["notifications"] as? Bool ?? false; recordAdvertisements = args["advertisements"] as? Bool ?? false; result(nil) } catch { result(fail("STORAGE_ERROR", error.localizedDescription)) }
    case "queryRecords":
      let after = (args["afterId"] as? NSNumber)?.int64Value ?? 0; let limit = (args["limit"] as? NSNumber)?.intValue ?? 100
      guard after >= 0 && (1...1000).contains(limit) else { result(fail("INVALID_ARGUMENT", "Invalid pagination")); return }
      do { if store == nil { store = try EventStore() }; result(try store!.query(after: after, limit: limit)) } catch { result(fail("STORAGE_ERROR", error.localizedDescription)) }
    case "clearRecords":
      do { if store == nil { store = try EventStore() }; result(try store!.clear()) } catch { result(fail("STORAGE_ERROR", error.localizedDescription)) }
    case "adapterState": result(state())
    case "requestPermissions": result(central.state == .poweredOn)
    case "startScan":
      guard central.state == .poweredOn else { result(fail("BLUETOOTH_ERROR", "Bluetooth is not powered on")); return }
      scanLocalName = args["localName"] as? String
      let services = (args["serviceUuid"] as? String).map { [CBUUID(string: $0)] }
      central.scanForPeripherals(withServices: services, options: nil)
      scanTimer?.invalidate()
      if let ms = args["timeoutMs"] as? Int { scanTimer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: false) { [weak self] _ in self?.central.stopScan() } }
      result(nil)
    case "stopScan": scanTimer?.invalidate(); central.stopScan(); result(nil)
    case "connect":
      guard let p = peripheral(id) else { result(fail("NOT_FOUND", "Peripheral not found; scan first")); return }
      if p.state == .connected { result(nil); return }
      begin(id, result) { p.delegate = self; central.connect(p) }
    case "disconnect":
      guard let p = peripheral(id) else { result(fail("NOT_FOUND", "Peripheral not found")); return }
      finish(id, fail("DISCONNECTED", "Disconnected")); central.cancelPeripheralConnection(p); result(nil)
    case "discoverServices":
      guard let p = peripheral(id), p.state == .connected else { result(fail("NOT_CONNECTED", "Peripheral not connected")); return }
      begin(id, result) { discovered[id] = []; p.discoverServices(nil) }
    case "read", "write", "setNotify":
      guard let p = peripheral(id), p.state == .connected, let c = characteristic(p, args) else { result(fail("NOT_FOUND", "Connected characteristic not found")); return }
      if call.method == "write", let bytes = args["value"] as? FlutterStandardTypedData, args["withoutResponse"] as? Bool == true {
        p.writeValue(bytes.data, for: c, type: .withoutResponse); result(nil); return
      }
      begin(id, result) {
        switch call.method {
        case "read": pendingRead[id] = c; p.readValue(for: c)
        case "write": if let bytes = args["value"] as? FlutterStandardTypedData { p.writeValue(bytes.data, for: c, type: .withResponse) } else { finish(id, fail("INVALID_ARGUMENT", "Missing value")) }
        default: p.setNotifyValue(args["enabled"] as? Bool ?? false, for: c)
        }
      }
    case "saveDevice":
      guard UUID(uuidString: id) != nil else { result(fail("INVALID_ARGUMENT", "Invalid UUID")); return }
      var list = UserDefaults.standard.stringArray(forKey: savedKey) ?? []; if !list.contains(id) { list.append(id) }; UserDefaults.standard.set(list, forKey: savedKey); result(nil)
    case "savedDevices": result(UserDefaults.standard.stringArray(forKey: savedKey) ?? [])
    case "forgetDevice": var list = UserDefaults.standard.stringArray(forKey: savedKey) ?? []; list.removeAll { $0 == id }; UserDefaults.standard.set(list, forKey: savedKey); result(nil)
    case "isCompanionSupported": result(false)
    case "associate", "associations", "disassociate", "observe": result(fail("UNSUPPORTED", "Android CompanionDeviceManager is unavailable on iOS"))
    default: result(FlutterMethodNotImplemented)
    }
  }
  public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    if let expected = scanLocalName, name != expected { return }
    let id = peripheral.identifier.uuidString; peripherals[id] = peripheral; peripheral.delegate = self
    if recordAdvertisements { record { try $0.append(kind: "advertisement", device: id, name: name, rssi: RSSI.intValue) } }
    sink?(["type": "scan", "id": id, "name": name as Any? ?? NSNull(), "rssi": RSSI])
  }
  public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { let id = peripheral.identifier.uuidString; sink?(["type": "connection", "id": id, "state": "connected"]); finish(id) }
  public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { finish(peripheral.identifier.uuidString, fail("CONNECT_FAILED", error?.localizedDescription ?? "Connection failed")) }
  public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { let id = peripheral.identifier.uuidString; sink?(["type": "connection", "id": id, "state": "disconnected"]); finish(id, fail("DISCONNECTED", error?.localizedDescription ?? "Disconnected")) }
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let id = peripheral.identifier.uuidString
    if let error = error { finish(id, fail("GATT_ERROR", error.localizedDescription)); return }
    guard let services = peripheral.services, !services.isEmpty else { finish(id, []); return }
    for service in services { peripheral.discoverCharacteristics(nil, for: service) }
  }
  public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let id = peripheral.identifier.uuidString
    if let error = error { finish(id, fail("GATT_ERROR", error.localizedDescription)); return }
    discovered[id, default: []].append(contentsOf: service.characteristics ?? [])
    guard peripheral.services?.allSatisfy({ $0.characteristics != nil }) == true else { return }
    let chars = discovered.removeValue(forKey: id) ?? []
    finish(id, chars.map { c -> [String: Any] in
      var props: [String] = []
      if c.properties.contains(.read) { props.append("read") }; if c.properties.contains(.write) { props.append("write") }; if c.properties.contains(.writeWithoutResponse) { props.append("writeWithoutResponse") }; if c.properties.contains(.notify) { props.append("notify") }; if c.properties.contains(.indicate) { props.append("indicate") }
      return ["service": c.service?.uuid.uuidString ?? "", "uuid": c.uuid.uuidString, "properties": props]
    })
  }
  public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    let id = peripheral.identifier.uuidString
    if pendingRead[id] === c { finish(id, error.map { fail("GATT_ERROR", $0.localizedDescription) } ?? FlutterStandardTypedData(bytes: c.value ?? Data())) }
    else if error == nil { if recordValues { record { try $0.append(kind: "notification", device: id, service: c.service?.uuid.uuidString, characteristic: c.uuid.uuidString, value: c.value) } }; sink?(["type": "value", "id": id, "service": c.service?.uuid.uuidString ?? "", "characteristic": c.uuid.uuidString, "value": FlutterStandardTypedData(bytes: c.value ?? Data())]) }
  }
  public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) { finish(peripheral.identifier.uuidString, error.map { fail("GATT_ERROR", $0.localizedDescription) }) }
  public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) { finish(peripheral.identifier.uuidString, error.map { fail("GATT_ERROR", $0.localizedDescription) }) }
}
