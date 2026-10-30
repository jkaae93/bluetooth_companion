import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:bluetooth_companion/bluetooth_companion.dart';

void main() => runApp(const MaterialApp(home: Example()));

class Example extends StatefulWidget {
  const Example({super.key});
  @override
  State<Example> createState() => _ExampleState();
}

class _ExampleState extends State<Example> {
  final ble = BluetoothCompanion();
  final devices = <String, BleDevice>{};
  final value = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? subscription;
  List<BleCharacteristic> characteristics = [];
  List<CompanionAssociation> associations = [];
  String? selected;
  String status = 'Ready';
  @override
  void initState() {
    super.initState();
    subscription = ble.events.listen((e) {
      if (!mounted) return;
      setState(() {
        if (e['type'] == 'scan') {
          final d = BleDevice.fromMap(e);
          devices[d.id] = d;
        }
        status = e.toString();
      });
    });
  }

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Bluetooth Companion')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(status),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton(
              onPressed: () => run(() async {
                final granted = await ble.requestPermissions();
                setState(() => status = 'Permission: $granted');
              }),
              child: const Text('Permissions'),
            ),
            ElevatedButton(
              onPressed: () => run(
                () => ble.startScan(timeout: const Duration(seconds: 15)),
              ),
              child: const Text('Scan'),
            ),
            ElevatedButton(
              onPressed: () => run(ble.stopScan),
              child: const Text('Stop'),
            ),
            ElevatedButton(
              onPressed: () => run(() async {
                final a = await ble.associate();
                if (a != null) {
                  associations = await ble.associations();
                  setState(() => status = 'Associated: ${a.address}');
                }
              }),
              child: const Text('Associate (Android)'),
            ),
            ElevatedButton(
              onPressed: () => run(() async {
                associations = await ble.associations();
                setState(() {});
              }),
              child: const Text('Associations'),
            ),
          ],
        ),
        for (final a in associations)
          ListTile(
            title: Text(a.address ?? '${a.id}'),
            subtitle: Text(a.name ?? ''),
            trailing: Wrap(
              children: [
                IconButton(
                  onPressed: () => run(() => ble.observe(a)),
                  icon: const Icon(Icons.visibility),
                ),
                IconButton(
                  onPressed: () => run(() async {
                    await ble.disassociate(a);
                    associations = await ble.associations();
                    setState(() {});
                  }),
                  icon: const Icon(Icons.delete),
                ),
              ],
            ),
          ),
        for (final d in devices.values)
          ListTile(
            title: Text(d.name ?? 'Unknown'),
            subtitle: Text('${d.id}  RSSI: ${d.rssi}'),
            onTap: () => run(() async {
              await ble.connect(d.id);
              selected = d.id;
              characteristics = await ble.discoverServices(d.id);
              setState(() {});
            }),
            trailing: IconButton(
              onPressed: () => run(() => ble.disconnect(d.id)),
              icon: const Icon(Icons.link_off),
            ),
          ),
        if (selected != null) ...[
          Text('Connected: $selected'),
          TextField(
            controller: value,
            decoration: const InputDecoration(labelText: 'Write text'),
          ),
          for (final c in characteristics)
            ListTile(
              title: Text(c.uuid),
              subtitle: Text('${c.service}\n${c.properties.join(', ')}'),
              trailing: Wrap(
                children: [
                  IconButton(
                    onPressed: () => run(() async {
                      final v = await ble.read(selected!, c.service, c.uuid);
                      setState(() => status = v.toString());
                    }),
                    icon: const Icon(Icons.download),
                  ),
                  IconButton(
                    onPressed: () => run(
                      () => ble.write(
                        selected!,
                        c.service,
                        c.uuid,
                        Uint8List.fromList(utf8.encode(value.text)),
                      ),
                    ),
                    icon: const Icon(Icons.upload),
                  ),
                  IconButton(
                    onPressed: () => run(
                      () => ble.setNotify(selected!, c.service, c.uuid, true),
                    ),
                    icon: const Icon(Icons.notifications),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}
