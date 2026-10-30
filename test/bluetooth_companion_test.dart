import 'package:bluetooth_companion/bluetooth_companion.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bluetooth_companion/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'adapterState':
          return 'on';
        case 'read':
          return Uint8List.fromList([1, 2]);
        case 'discoverServices':
          return [
            {
              'service': 's',
              'uuid': 'c',
              'properties': ['read'],
            },
          ];
        case 'queryRecords':
          return [
            {
              'id': 1,
              'kind': 'notification',
              'deviceId': 'mock',
              'value': Uint8List.fromList([1, 2]),
            },
          ];
        case 'clearRecords':
          return 1;
        case 'associations':
          return [
            {'id': 2, 'address': 'aa:bb', 'name': 'test'},
          ];
        default:
          return null;
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('forwards BLE operations and maps results', () async {
    final ble = BluetoothCompanion();
    expect(await ble.adapterState(), 'on');
    await ble.startScan(timeout: const Duration(seconds: 2));
    expect(calls.last.arguments['timeoutMs'], 2000);
    await ble.startScan(
      localName: 'Sensor',
      serviceUuid: '0000180d-0000-1000-8000-00805f9b34fb',
    );
    expect(calls.last.arguments['localName'], 'Sensor');
    expect(
      calls.last.arguments['serviceUuid'],
      '0000180d-0000-1000-8000-00805f9b34fb',
    );
    await expectLater(
      ble.startScan(serviceUuid: 'invalid'),
      throwsArgumentError,
    );
    final chars = await ble.discoverServices('device');
    expect(chars.single.properties, ['read']);
    expect(await ble.read('device', 's', 'c'), [1, 2]);
    await ble.write(
      'device',
      's',
      'c',
      Uint8List.fromList([3]),
      withoutResponse: true,
    );
    expect(calls.last.arguments['withoutResponse'], true);
  });
  test('normalizes association and sends observation arguments', () async {
    final ble = BluetoothCompanion();
    final a = (await ble.associations()).single;
    expect(a.address, 'AA:BB');
    await ble.observe(a, enabled: false);
    expect(calls.last.arguments, {
      'id': 2,
      'address': 'AA:BB',
      'enabled': false,
    });
  });
  test('recording controls and paginated records', () async {
    final ble = BluetoothCompanion();
    await ble.configureRecording(advertisements: true);
    expect(calls.last.arguments, {
      'notifications': true,
      'advertisements': true,
    });
    final records = await ble.queryRecords(afterId: 5, limit: 10);
    expect(calls.last.arguments, {'afterId': 5, 'limit': 10});
    expect(records.single['value'], [1, 2]);
    expect(await ble.clearRecords(), 1);
    await expectLater(ble.queryRecords(limit: 0), throwsArgumentError);
  });
  test('propagates platform errors', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'PERMISSION_DENIED'),
    );
    expect(
      BluetoothCompanion().connect('a'),
      throwsA(isA<PlatformException>()),
    );
  });
}
