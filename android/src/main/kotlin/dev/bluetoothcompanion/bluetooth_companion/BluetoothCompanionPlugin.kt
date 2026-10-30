package dev.bluetoothcompanion.bluetooth_companion

import android.Manifest
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.companion.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.*
import io.flutter.plugin.common.*
import java.util.UUID
import java.util.regex.Pattern

@Suppress("DEPRECATION", "MissingPermission")
class BluetoothCompanionPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private val handler = Handler(Looper.getMainLooper())
    private val adapter get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) { BluetoothAdapter.STATE_ON -> "on"; BluetoothAdapter.STATE_OFF -> "off"; else -> "unknown" }
            emit(mapOf("type" to "adapter", "state" to state))
        }
    }
    private val gatts = mutableMapOf<String, BluetoothGatt>()
    private val pending = mutableMapOf<String, MethodChannel.Result>()
    private var permissionResult: MethodChannel.Result? = null
    private var associationResult: MethodChannel.Result? = null
    private var scanTimeout: Runnable? = null
    private var scanLocalName: String? = null
    private lateinit var store: EventStore
    private var recordValues = false
    private var recordAdvertisements = false
    private fun record(block: () -> Unit) { try { block() } catch (e: Exception) { emit(mapOf("type" to "error", "code" to "STORAGE_ERROR", "message" to (e.message ?: "Storage error"))) } }
    private val scan = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName
            if (scanLocalName != null && name != scanLocalName) return
            if (recordAdvertisements) record { store.append("advertisement", result.device.address, value = result.scanRecord?.bytes, name = name, rssi = result.rssi) }
            emit(mapOf("type" to "scan", "id" to result.device.address, "name" to name, "rssi" to result.rssi))
        }
        override fun onScanFailed(errorCode: Int) { emit(mapOf("type" to "error", "code" to "SCAN_FAILED", "message" to errorCode.toString())) }
    }
    private fun emit(event: Map<String, Any?>) { handler.post { sink?.success(event) } }
    private fun finish(id: String, value: Any? = null, error: String? = null) { handler.post { pending.remove(id)?.let { if (error == null) it.success(value) else it.error("GATT_ERROR", error, null) } } }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val id = gatt.device.address
            emit(mapOf("type" to "connection", "id" to id, "state" to if (newState == BluetoothProfile.STATE_CONNECTED) "connected" else "disconnected"))
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) finish(id)
            else if (newState == BluetoothProfile.STATE_DISCONNECTED) { gatts.remove(id); gatt.close(); finish(id, error = "Connection closed ($status)") }
        }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val list = gatt.services.flatMap { s -> s.characteristics.map { c ->
                val p = c.properties
                mapOf("service" to s.uuid.toString(), "uuid" to c.uuid.toString(), "properties" to listOfNotNull(
                    "read".takeIf { p and BluetoothGattCharacteristic.PROPERTY_READ != 0 },
                    "write".takeIf { p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 },
                    "writeWithoutResponse".takeIf { p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0 },
                    "notify".takeIf { p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0 },
                    "indicate".takeIf { p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0 })) } }
            finish(gatt.device.address, list, if (status == 0) null else "Discovery failed ($status)")
        }
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) { finish(g.device.address, c.value, if (status == 0) null else "Read failed ($status)") }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) { finish(g.device.address, error = if (status == 0) null else "Write failed ($status)") }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) { finish(g.device.address, error = if (status == 0) null else "Notification setup failed ($status)") }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) { if (recordValues) record { store.append("notification", g.device.address, c.service.uuid.toString(), c.uuid.toString(), c.value) }; emit(mapOf("type" to "value", "id" to g.device.address, "service" to c.service.uuid.toString(), "characteristic" to c.uuid.toString(), "value" to c.value)) }
    }
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        store = EventStore(context)
        context.registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        methods = MethodChannel(binding.binaryMessenger, "bluetooth_companion/methods"); methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "bluetooth_companion/events"); events.setStreamHandler(this)
        PresenceService.listener = { address, appeared -> emit(mapOf("type" to "presence", "address" to address, "appeared" to appeared)) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        try { adapter?.bluetoothLeScanner?.stopScan(scan) } catch (_: Exception) {}
        scanTimeout?.let { handler.removeCallbacks(it) }
        gatts.values.forEach { it.close() }; gatts.clear()
        pending.values.forEach { it.error("DETACHED", "Plugin detached", null) }; pending.clear()
        associationResult?.error("DETACHED", "Plugin detached", null); associationResult = null
        permissionResult?.error("DETACHED", "Plugin detached", null); permissionResult = null
        store.close()
        context.unregisterReceiver(adapterReceiver)
        PresenceService.listener = null; methods.setMethodCallHandler(null); events.setStreamHandler(null); sink = null
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    override fun onAttachedToActivity(b: ActivityPluginBinding) { binding = b; activity = b.activity; b.addActivityResultListener(this); b.addRequestPermissionsResultListener(this) }
    override fun onDetachedFromActivity() { binding?.removeActivityResultListener(this); binding?.removeRequestPermissionsResultListener(this); binding = null; activity = null; associationResult?.error("NO_ACTIVITY", "Activity detached", null); associationResult = null; permissionResult?.error("NO_ACTIVITY", "Activity detached", null); permissionResult = null }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    private fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != 7321) return false
        permissionResult?.success(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }); permissionResult = null; return true
    }
    private fun begin(id: String, result: MethodChannel.Result, action: () -> Boolean) {
        if (pending.containsKey(id)) { result.error("BUSY", "A GATT operation is already pending for this device", null); return }
        pending[id] = result
        if (!action()) { pending.remove(id); result.error("GATT_ERROR", "Could not start GATT operation", null); return }
        handler.postDelayed({ if (pending[id] === result) { pending.remove(id); gatts.remove(id)?.close(); result.error("TIMEOUT", "GATT operation timed out; reconnect required", null) } }, 30000)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val id = call.argument<String>("deviceId") ?: ""
            when (call.method) {
                "dispose" -> { scanTimeout?.let { handler.removeCallbacks(it) }; adapter?.bluetoothLeScanner?.stopScan(scan); gatts.values.forEach { it.disconnect(); it.close() }; gatts.clear(); pending.values.forEach { it.error("DISPOSED", "Bluetooth disposed", null) }; pending.clear(); result.success(null) }
                "configureRecording" -> { recordValues = call.argument<Boolean>("notifications") == true; recordAdvertisements = call.argument<Boolean>("advertisements") == true; result.success(null) }
                "queryRecords" -> { val after = call.argument<Number>("afterId")?.toLong() ?: 0; val limit = call.argument<Int>("limit") ?: 100; require(after >= 0 && limit in 1..1000); result.success(store.query(after, limit)) }
                "clearRecords" -> result.success(store.clear())
                "adapterState" -> result.success(if (adapter == null) "unsupported" else if (adapter.isEnabled) "on" else "off")
                "requestPermissions" -> { val a = activity ?: throw IllegalStateException("Activity unavailable"); if (permissionResult != null) throw IllegalStateException("Permission request pending"); val missing = requiredPermissions().filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }; if (missing.isEmpty()) result.success(true) else { permissionResult = result; a.requestPermissions(missing.toTypedArray(), 7321) } }
                "startScan" -> { val scanner = adapter?.bluetoothLeScanner ?: throw IllegalStateException("Bluetooth unavailable"); val uuid = call.argument<String>("serviceUuid")?.let { ParcelUuid(UUID.fromString(it)) }; scanner.stopScan(scan); scanLocalName = call.argument<String>("localName"); val filters = if (uuid == null) emptyList() else listOf(ScanFilter.Builder().setServiceUuid(uuid).build()); scanner.startScan(filters, ScanSettings.Builder().build(), scan); scanTimeout?.let { handler.removeCallbacks(it) }; (call.argument<Number>("timeoutMs")?.toLong())?.let { ms -> val task = Runnable { try { scanner.stopScan(scan) } catch (_: Exception) {} }; scanTimeout = task; handler.postDelayed(task, ms) }; result.success(null) }
                "stopScan" -> { scanTimeout?.let { handler.removeCallbacks(it) }; adapter?.bluetoothLeScanner?.stopScan(scan); result.success(null) }
                "connect" -> { if (gatts.containsKey(id)) throw IllegalStateException("Device already connected or connecting"); begin(id, result) { val g = adapter.getRemoteDevice(id).connectGatt(context, false, callback); if (g == null) false else { gatts[id] = g; true } } }
                "disconnect" -> { val g = gatts.remove(id); g?.disconnect(); g?.close(); pending.remove(id)?.error("DISCONNECTED", "Device disconnected", null); result.success(null) }
                "discoverServices" -> { val g = gatts[id] ?: throw IllegalStateException("Device not connected"); begin(id, result) { g.discoverServices() } }
                "read", "write", "setNotify" -> { val g = gatts[id] ?: throw IllegalStateException("Device not connected"); val c = g.getService(UUID.fromString(call.argument<String>("service")))?.getCharacteristic(UUID.fromString(call.argument<String>("characteristic"))) ?: throw IllegalArgumentException("Characteristic not found")
                    when (call.method) {
                        "read" -> begin(id, result) { g.readCharacteristic(c) }
                        "write" -> begin(id, result) { c.writeType = if (call.argument<Boolean>("withoutResponse") == true) BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; c.value = call.argument<ByteArray>("value"); g.writeCharacteristic(c) }
                        else -> { val enabled = call.argument<Boolean>("enabled") == true; val d = c.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")) ?: throw IllegalStateException("CCCD missing"); begin(id, result) { if (!g.setCharacteristicNotification(c, enabled)) false else { d.value = if (!enabled) BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE else if (c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE; g.writeDescriptor(d) } } }
                    }
                }
                "isCompanionSupported" -> result.success(Build.VERSION.SDK_INT >= 26 && context.packageManager.hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP))
                "associate" -> associate(call, result)
                "associations" -> { if (Build.VERSION.SDK_INT < 26) throw UnsupportedOperationException("Requires Android 8"); val cdm = context.getSystemService(CompanionDeviceManager::class.java); result.success(if (Build.VERSION.SDK_INT >= 33) cdm.myAssociations.map { mapOf("id" to it.id, "address" to it.deviceMacAddress?.toString()?.uppercase(), "name" to it.displayName?.toString()) } else cdm.associations.map { mapOf("address" to it) }) }
                "disassociate" -> { if (Build.VERSION.SDK_INT < 26) throw UnsupportedOperationException("Requires Android 8"); val cdm = context.getSystemService(CompanionDeviceManager::class.java); val aid = call.argument<Int>("id"); if (Build.VERSION.SDK_INT >= 33 && aid != null) cdm.disassociate(aid) else cdm.disassociate(call.argument<String>("address") ?: throw IllegalArgumentException("Address required")); result.success(null) }
                "observe" -> observe(call, result)
                "saveDevice", "savedDevices", "forgetDevice" -> result.error("UNSUPPORTED", "iOS only", null)
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) { result.error("PERMISSION_DENIED", e.message, null) } catch (e: UnsupportedOperationException) { result.error("UNSUPPORTED", e.message, null) } catch (e: Exception) { result.error("BLUETOOTH_ERROR", e.message, null) }
    }
    private fun associate(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 26) throw UnsupportedOperationException("Requires Android 8")
        val act = activity ?: throw IllegalStateException("Activity unavailable")
        if (associationResult != null) throw IllegalStateException("Association already pending")
        val filter = BluetoothLeDeviceFilter.Builder()
        call.argument<String>("namePattern")?.let { filter.setNamePattern(Pattern.compile(it)) }
        call.argument<String>("address")?.let { filter.setScanFilter(ScanFilter.Builder().setDeviceAddress(it).build()) }
        val request = AssociationRequest.Builder().addDeviceFilter(filter.build()).setSingleDevice(false).build()
        associationResult = result
        val cdm = context.getSystemService(CompanionDeviceManager::class.java)
        handler.postDelayed({ if (associationResult === result) { associationResult = null; result.error("TIMEOUT", "Association timed out", null) } }, 60000)
        try { cdm.associate(request, object : CompanionDeviceManager.Callback() {
            override fun onAssociationPending(sender: IntentSender) { onDeviceFound(sender) }
            override fun onAssociationCreated(info: AssociationInfo) { associationResult?.success(mapOf("id" to info.id, "address" to info.deviceMacAddress?.toString()?.uppercase(), "name" to info.displayName?.toString())); associationResult = null }
            override fun onDeviceFound(sender: IntentSender) { try { act.startIntentSenderForResult(sender, 7322, null, 0, 0, 0) } catch (e: Exception) { associationResult?.error("ASSOCIATION_FAILED", e.message, null); associationResult = null } }
            override fun onFailure(error: CharSequence?) { associationResult?.error("ASSOCIATION_FAILED", error?.toString(), null); associationResult = null }
        }, handler) } catch (e: Exception) { associationResult = null; throw e }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != 7322) return false
        if (resultCode != Activity.RESULT_OK) associationResult?.success(null) else {
            val info = if (Build.VERSION.SDK_INT >= 33) data?.getParcelableExtra<AssociationInfo>(CompanionDeviceManager.EXTRA_ASSOCIATION) else null
            val scanResult = if (info == null) data?.getParcelableExtra<ScanResult>(CompanionDeviceManager.EXTRA_DEVICE) else null
            associationResult?.success(if (info != null) mapOf("id" to info.id, "address" to info.deviceMacAddress?.toString()?.uppercase(), "name" to info.displayName?.toString()) else scanResult?.device?.let { mapOf("address" to it.address, "name" to it.name) })
        }
        associationResult = null; return true
    }
    private fun observe(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 31) throw UnsupportedOperationException("Presence requires Android 12")
        val address = call.argument<String>("address") ?: throw IllegalArgumentException("Address required")
        val enabled = call.argument<Boolean>("enabled") == true
        val cdm = context.getSystemService(CompanionDeviceManager::class.java)
        if (Build.VERSION.SDK_INT >= 36) {
            val associationId = call.argument<Int>("id") ?: cdm.myAssociations.firstOrNull { it.deviceMacAddress?.toString()?.equals(address, true) == true }?.id ?: throw IllegalArgumentException("Association not found")
            val request = ObservingDevicePresenceRequest.Builder().setAssociationId(associationId).build()
            if (enabled) cdm.startObservingDevicePresence(request) else cdm.stopObservingDevicePresence(request)
        } else if (enabled) cdm.startObservingDevicePresence(address) else cdm.stopObservingDevicePresence(address)
        val prefs = context.getSharedPreferences("bluetooth_companion", Context.MODE_PRIVATE)
        val addresses = prefs.getStringSet("observed", emptySet())!!.toMutableSet(); if (enabled) addresses.add(address) else addresses.remove(address); prefs.edit().putStringSet("observed", addresses).apply()
        result.success(null)
    }
}
