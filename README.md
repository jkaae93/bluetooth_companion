# Bluetooth Companion

A Flutter plugin for Bluetooth Low Energy (BLE) central operations, implemented with native Android Bluetooth and iOS Core Bluetooth APIs. Android also provides CompanionDeviceManager (CDM) association and presence observation.

**Status:** Early development. The platform implementations have not yet been validated on physical devices. The API may change before a stable release.

## Requirements

| Component | Minimum |
| --- | --- |
| Flutter / Dart | Flutter 3.41.6 / Dart 3.11.4 |
| Android BLE | Android 7 (API 24) |
| Android CDM association | Android 8 (API 26) with companion device setup feature |
| Android CDM presence | Android 12 (API 31) |
| iOS BLE | iOS 13 |

Android and iOS are the supported platforms. BLE operations use Android Bluetooth LE and iOS Core Bluetooth directly; no other Flutter Bluetooth package is required.

## Installation and platform setup

Add the package to your app's `pubspec.yaml` after it is published. For local development use a path dependency:

```yaml
dependencies:
  bluetooth_companion:
    path: ../bluetooth-companion
```

The Android plugin manifest declares Bluetooth scan/connect, legacy location, companion presence and boot permissions. Call `requestPermissions()` before scanning or connecting. Android 11 and earlier require Location Services for ordinary BLE scanning. The manifest sets `neverForLocation` on `BLUETOOTH_SCAN`; if the app derives location, configure the host manifest appropriately. CDM association and BLE scanning have different permission requirements.

On iOS, add `NSBluetoothAlwaysUsageDescription` to the app's `Info.plist`, with a description of why Bluetooth is needed. `requestPermissions()` reports whether the central manager is currently powered on; it does not explicitly request permission or distinguish authorization from power state. Core Bluetooth controls the prompt and its timing.

## BLE quick start

```dart
import 'dart:async';
import 'package:bluetooth_companion/bluetooth_companion.dart';

final bluetooth = BluetoothCompanion();
late StreamSubscription<Map<String, dynamic>> subscription;

Future<void> scan() async {
  subscription = bluetooth.events.listen((event) {
    if (event['type'] == 'scan') {
      final device = BleDevice.fromMap(event);
      print('${device.name}: ${device.id} (${device.rssi})');
    }
  });
  if (await bluetooth.requestPermissions()) {
    await bluetooth.startScan(timeout: const Duration(seconds: 10));
  }
}

Future<void> connectAndRead(String deviceId) async {
  await bluetooth.stopScan();
  await bluetooth.connect(deviceId);
  final characteristics = await bluetooth.discoverServices(deviceId);
  final readable = characteristics.firstWhere(
    (characteristic) => characteristic.properties.contains('read'),
  );
  final value = await bluetooth.read(deviceId, readable.service, readable.uuid);
  print(value);
  // Use bluetooth.write(...) or bluetooth.setNotify(..., true) as needed.
}

Future<void> cleanup() async {
  await bluetooth.dispose();
  await subscription.cancel();
}
```

Device IDs are Android MAC addresses or iOS Core Bluetooth UUIDs and cannot be exchanged between platforms. Discovery must precede characteristic operations. The caller should serialize GATT operations per device; overlapping operations return `BUSY`. GATT operations time out after 30 seconds. On Android, reconnect after a GATT timeout.

### Events

`events` is a broadcast stream of maps. Subscribe before starting operations; events are not replayed. The plugin emits:

| `type` | Fields | Platform |
| --- | --- | --- |
| `adapter` | `state`: `on`, `off`, `unknown`, or iOS `unauthorized` / `unsupported` | Android, iOS |
| `scan` | `id`, nullable `name`, `rssi` | Android, iOS |
| `connection` | `id`, `state`: `connected` or `disconnected` | Android, iOS |
| `value` | `id`, `service`, `characteristic`, `value` (`Uint8List`) | Android, iOS |
| `presence` | `address`, `appeared` | Android API 31+ |
| `error` | `code`, `message`; asynchronous scan failure | Android |

## Android companion devices

CDM associates the app with a device; it does not establish a GATT connection. Association requires user interaction with the system dialog. `associate` accepts an optional name regular expression and/or Bluetooth address; cancellation returns `null`.

```dart
Future<void> associate(BluetoothCompanion bluetooth) async {
  if (!await bluetooth.isCompanionSupported()) return;
  final association = await bluetooth.associate(namePattern: '.*My Device.*');
  if (association == null) return;
  final all = await bluetooth.associations();
  print('Associated devices: ${all.length}');
  // Requires Android 12+ and an association with an address.
  await bluetooth.observe(association);
  // Later: await bluetooth.observe(association, enabled: false);
  // To remove: await bluetooth.disassociate(association);
}
```

Presence events reach Dart only while the Flutter engine and stream listener are active. Observation is restored after boot or package update on a best-effort basis. CDM, presence, and background execution depend on OS capabilities and permission state; background launch and automatic reconnection are not provided.

## iOS saved devices

`saveDevice(id)`, `savedDevices()`, and `forgetDevice(id)` persist iOS UUID strings in `UserDefaults`. Connecting with a saved UUID asks Core Bluetooth to retrieve the peripheral; retrieval can fail. This is local storage, not Android-style system association or presence monitoring. State restoration and AccessorySetupKit are not implemented.

## Errors

Native failures surface as `PlatformException`. Codes include `UNSUPPORTED`, `PERMISSION_DENIED`, `BLUETOOTH_ERROR`, `BUSY`, `TIMEOUT`, `GATT_ERROR`, `DISCONNECTED`, `NOT_FOUND`, `NOT_CONNECTED`, `CONNECT_FAILED`, `INVALID_ARGUMENT`, `ASSOCIATION_FAILED`, `NO_ACTIVITY`, `DETACHED`, and `DISPOSED`. Codes and messages depend on platform and operation. An Android asynchronous scan failure arrives as an `error` event. Check both the code and the operation; do not treat this list as an exhaustive stable error contract.

## Development

```sh
flutter pub get
flutter analyze
flutter test
cd example
flutter run
```

The example app includes scanning, connection, GATT controls and Android CDM controls. GitHub Actions is configured to run analysis, Dart tests, an Android debug build, and an iOS simulator build. These checks do not validate radio behavior on physical devices.

### Filter scans by advertised name and service

```dart
await bluetooth.startScan(
  localName: 'Sensor',
  serviceUuid: '0000180d-0000-1000-8000-00805f9b34fb',
  timeout: const Duration(seconds: 10),
);
```

Both filters are optional and, when supplied together, both must match. The name is an exact, case-sensitive match against the advertised local name, not the cached device name. The service UUID must be a full 128-bit UUID and must be present in the advertisement. Devices with no advertised local name do not match a name filter. iOS may omit the local name for background advertisers; a name filter can therefore exclude them even when their service matches. iOS background scanning also requires service UUIDs and is subject to system restrictions. This scan API uses an in-process callback; it does not implement Android PendingIntent scanning, persistent background collection, motion policies, or SQLite storage.

### Callback event recording (experimental)

Call `configureRecording(notifications: true, advertisements: false)` to save notification callbacks while the native plugin is active. Enable `advertisements` to also save matching scan results. Query with `queryRecords(afterId: 0, limit: 100)` and use the final ID for subsequent pages; `clearRecords()` deletes all records. Values are raw bytes and `receivedAt` is Unix milliseconds. Android saves scan record bytes; iOS exposes parsed advertisements rather than raw packets, so its advertisement value is null. Motion is currently `unknown`. Recording settings are in memory and must be enabled again after plugin recreation. This is not background collection: Flutter engine termination, disconnects and OS restrictions can prevent records from being captured.
