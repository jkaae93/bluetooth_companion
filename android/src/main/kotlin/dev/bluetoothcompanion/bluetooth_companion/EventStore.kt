package dev.bluetoothcompanion.bluetooth_companion

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

/** Durable event log shared by native callbacks. */
internal class EventStore(context: Context) : SQLiteOpenHelper(context, "bluetooth_companion.db", null, 1) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, device_id TEXT NOT NULL, service TEXT, characteristic TEXT, received_at INTEGER NOT NULL, value BLOB, name TEXT, rssi INTEGER, motion TEXT NOT NULL)")
    }
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
    @Synchronized fun append(kind: String, device: String, service: String? = null, characteristic: String? = null, value: ByteArray? = null, name: String? = null, rssi: Int? = null) {
        val values = ContentValues().apply {
            put("kind", kind); put("device_id", device); put("service", service); put("characteristic", characteristic)
            put("received_at", System.currentTimeMillis()); put("value", value); put("name", name); put("rssi", rssi); put("motion", "unknown")
        }
        writableDatabase.insertOrThrow("events", null, values)
    }
    @Synchronized fun query(after: Long, limit: Int): List<Map<String, Any?>> {
        val rows = mutableListOf<Map<String, Any?>>()
        readableDatabase.rawQuery("SELECT id, kind, device_id, service, characteristic, received_at, value, name, rssi, motion FROM events WHERE id > ? ORDER BY id LIMIT ?", arrayOf(after.toString(), limit.toString())).use { c ->
            while (c.moveToNext()) rows.add(mapOf("id" to c.getLong(0), "kind" to c.getString(1), "deviceId" to c.getString(2), "service" to c.getString(3), "characteristic" to c.getString(4), "receivedAt" to c.getLong(5), "value" to if (c.isNull(6)) null else c.getBlob(6), "name" to c.getString(7), "rssi" to if (c.isNull(8)) null else c.getInt(8), "motion" to c.getString(9)))
        }
        return rows
    }
    @Synchronized fun clear(): Int = writableDatabase.delete("events", null, null)
}
