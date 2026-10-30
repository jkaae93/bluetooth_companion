package dev.bluetoothcompanion.bluetooth_companion

import android.companion.CompanionDeviceService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.companion.CompanionDeviceManager
import android.companion.DevicePresenceEvent
import android.companion.ObservingDevicePresenceRequest
import android.os.Build

class PresenceService : CompanionDeviceService() {
    companion object { var listener: ((String, Boolean) -> Unit)? = null }
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        val manager = getSystemService(CompanionDeviceManager::class.java)
        val address = manager.myAssociations.firstOrNull { it.id == event.associationId }?.deviceMacAddress?.toString()?.uppercase() ?: return
        when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED, DevicePresenceEvent.EVENT_BT_CONNECTED -> listener?.invoke(address, true)
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED, DevicePresenceEvent.EVENT_BT_DISCONNECTED -> listener?.invoke(address, false)
        }
    }
    override fun onDeviceAppeared(address: String) { listener?.invoke(address, true) }
    override fun onDeviceDisappeared(address: String) { listener?.invoke(address, false) }
}

class BootReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION", "MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT < 31) return
        val manager = context.getSystemService(CompanionDeviceManager::class.java)
        context.getSharedPreferences("bluetooth_companion", Context.MODE_PRIVATE).getStringSet("observed", emptySet())?.forEach {
            try { if (Build.VERSION.SDK_INT >= 36) { val id = manager.myAssociations.firstOrNull { a -> a.deviceMacAddress?.toString()?.equals(it, true) == true }?.id; if (id != null) manager.startObservingDevicePresence(ObservingDevicePresenceRequest.Builder().setAssociationId(id).build()) } else manager.startObservingDevicePresence(it) } catch (_: Exception) { }
        }
    }
}
