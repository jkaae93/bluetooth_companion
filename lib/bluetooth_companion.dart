import 'dart:async';
import 'package:flutter/services.dart';

/// A discovered Bluetooth Low Energy peripheral. IDs are platform-specific.
class BleDevice {
  const BleDevice({required this.id, this.name, this.rssi});
  final String id;
  final String? name;
  final int? rssi;
  factory BleDevice.fromMap(Map<dynamic, dynamic> m) => BleDevice(
    id: m['id'] as String,
    name: m['name'] as String?,
    rssi: m['rssi'] as int?,
  );
}

/// A GATT characteristic, identified within a discovered service.
class BleCharacteristic {
  const BleCharacteristic({
    required this.service,
    required this.uuid,
    required this.properties,
  });
  final String service;
  final String uuid;
  final List<String> properties;
  factory BleCharacteristic.fromMap(Map<dynamic, dynamic> m) =>
      BleCharacteristic(
        service: m['service'] as String,
        uuid: m['uuid'] as String,
        properties: (m['properties'] as List).cast<String>(),
      );
}

/// An Android CDM association. Older Android versions may not supply an ID.
class CompanionAssociation {
  const CompanionAssociation({this.id, this.address, this.name});
  final int? id;
  final String? address;
  final String? name;
  factory CompanionAssociation.fromMap(Map<dynamic, dynamic> m) =>
      CompanionAssociation(
        id: m['id'] as int?,
        address: (m['address'] as String?)?.toUpperCase(),
        name: m['name'] as String?,
      );
}

/// Native BLE central and Android companion device operations.
///
/// Events are broadcast maps with a `type`: adapter, scan, connection,
/// value, or presence. Subscriptions receive events only while Flutter runs.
class BluetoothCompanion {
  BluetoothCompanion({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('bluetooth_companion/methods'),
      _events = events ?? const EventChannel('bluetooth_companion/events');
  final MethodChannel _methods;
  final EventChannel _events;
  Stream<Map<String, dynamic>>? _stream;

  /// Broadcast platform events. Events are not replayed to new subscribers.
  /// See the README for event types and fields.
  Stream<Map<String, dynamic>> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .asBroadcastStream();
  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) =>
      _methods.invokeMethod<T>(method, args);

  /// Returns the current Bluetooth adapter state.
  Future<String> adapterState() async =>
      await _call<String>('adapterState') ?? 'unknown';

  /// Requests Android permissions; on iOS reports whether Bluetooth is on.
  Future<bool> requestPermissions() async =>
      await _call<bool>('requestPermissions') ?? false;

  /// Starts discovery with optional exact advertised local name and service UUID.
  /// Both filters must match when supplied. The UUID must be a full 128-bit UUID.
  Future<void> startScan({
    Duration? timeout,
    String? localName,
    String? serviceUuid,
  }) async {
    if (localName != null && localName.isEmpty) {
      throw ArgumentError.value(localName, 'localName', 'Must not be empty');
    }
    if (serviceUuid != null &&
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(serviceUuid)) {
      throw ArgumentError.value(
        serviceUuid,
        'serviceUuid',
        'Expected a 128-bit UUID',
      );
    }
    await _call<void>('startScan', {
      'timeoutMs': timeout?.inMilliseconds,
      'localName': localName,
      'serviceUuid': serviceUuid,
    });
  }

  /// Stops discovery.
  Future<void> stopScan() async => _call<void>('stopScan');

  /// Connects to a device identified by its platform-specific ID.
  Future<void> connect(String deviceId) async =>
      _call<void>('connect', {'deviceId': deviceId});

  /// Disconnects a device.
  Future<void> disconnect(String deviceId) async =>
      _call<void>('disconnect', {'deviceId': deviceId});

  /// Discovers services and returns their characteristics.
  Future<List<BleCharacteristic>> discoverServices(String deviceId) async =>
      (await _call<List<dynamic>>('discoverServices', {'deviceId': deviceId}) ??
              [])
          .map((e) => BleCharacteristic.fromMap(e as Map))
          .toList();
  Map<String, Object?> _characteristic(
    String deviceId,
    String service,
    String characteristic,
  ) => {
    'deviceId': deviceId,
    'service': service,
    'characteristic': characteristic,
  };

  /// Reads a previously discovered characteristic.
  Future<Uint8List> read(
    String deviceId,
    String service,
    String characteristic,
  ) async =>
      await _call<Uint8List>(
        'read',
        _characteristic(deviceId, service, characteristic),
      ) ??
      Uint8List(0);

  /// Writes to a previously discovered characteristic.
  Future<void> write(
    String deviceId,
    String service,
    String characteristic,
    Uint8List value, {
    bool withoutResponse = false,
  }) async => _call<void>('write', {
    ..._characteristic(deviceId, service, characteristic),
    'value': value,
    'withoutResponse': withoutResponse,
  });

  /// Enables or disables characteristic notifications or indications.
  Future<void> setNotify(
    String deviceId,
    String service,
    String characteristic,
    bool enabled,
  ) async => _call<void>('setNotify', {
    ..._characteristic(deviceId, service, characteristic),
    'enabled': enabled,
  });

  /// Enables recording of callback events while the native plugin is active.
  Future<void> configureRecording({
    bool notifications = true,
    bool advertisements = false,
  }) async => _call<void>('configureRecording', {
    'notifications': notifications,
    'advertisements': advertisements,
  });

  /// Reads records in ascending ID order. Pass the last ID as [afterId] for the next page.
  Future<List<Map<String, dynamic>>> queryRecords({
    int afterId = 0,
    int limit = 100,
  }) async {
    if (afterId < 0 || limit < 1 || limit > 1000) {
      throw ArgumentError('Invalid pagination');
    }
    return (await _call<List<dynamic>>('queryRecords', {
              'afterId': afterId,
              'limit': limit,
            }) ??
            [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  /// Deletes all recorded events and returns the number deleted.
  Future<int> clearRecords() async => await _call<int>('clearRecords') ?? 0;

  /// Whether Android companion device association is available.
  Future<bool> isCompanionSupported() async =>
      await _call<bool>('isCompanionSupported') ?? false;

  /// Opens the Android association dialog; returns null on user cancellation.
  Future<CompanionAssociation?> associate({
    String? namePattern,
    String? address,
  }) async {
    final m = await _call<Map<dynamic, dynamic>>('associate', {
      'namePattern': namePattern,
      'address': address,
    });
    return m == null ? null : CompanionAssociation.fromMap(m);
  }

  /// Lists Android companion associations.
  Future<List<CompanionAssociation>> associations() async =>
      (await _call<List<dynamic>>('associations') ?? [])
          .map((e) => CompanionAssociation.fromMap(e as Map))
          .toList();

  /// Removes an Android companion association.
  Future<void> disassociate(CompanionAssociation association) async =>
      _call<void>('disassociate', {
        'id': association.id,
        'address': association.address,
      });

  /// Starts or stops Android presence observation for an associated device.
  Future<void> observe(
    CompanionAssociation association, {
    bool enabled = true,
  }) async => _call<void>('observe', {
    'id': association.id,
    'address': association.address,
    'enabled': enabled,
  });

  /// Saves an iOS Core Bluetooth UUID for subsequent retrieval.
  Future<void> saveDevice(String deviceId) async =>
      _call<void>('saveDevice', {'deviceId': deviceId});

  /// Returns locally saved iOS device UUIDs.
  Future<List<String>> savedDevices() async =>
      (await _call<List<dynamic>>('savedDevices') ?? []).cast<String>();

  /// Removes a locally saved iOS device UUID.
  Future<void> forgetDevice(String deviceId) async =>
      _call<void>('forgetDevice', {'deviceId': deviceId});

  /// Stops scanning and disconnects active devices.
  Future<void> dispose() async => _call<void>('dispose');
}
