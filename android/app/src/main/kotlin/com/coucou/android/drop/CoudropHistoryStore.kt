package com.coucou.android.drop

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

enum class TransferDirection {
    INCOMING,
    OUTGOING,
}

enum class TransferStatus {
    PENDING,
    IN_PROGRESS,
    COMPLETED,
    FAILED,
    CANCELLED,
}

data class CoudropRecord(
    val id: String,
    val name: String,
    val size: Long,
    val direction: TransferDirection,
    val status: TransferStatus,
    val timestampMs: Long,
    val uriString: String? = null,
    val mimeType: String = "application/octet-stream",
    val sha256: String = "",
)

/**
 * Persists recent Coudrop file transfers in private app storage.
 */
class CoudropHistoryStore(private val context: Context) {
    private val file = File(context.filesDir, "coudrop_history.json")
    private val lock = Any()
    private val maxItems = 50

    fun addRecord(record: CoudropRecord) {
        synchronized(lock) {
            val list = load().toMutableList()
            list.removeAll { it.id == record.id }
            list.add(0, record)
            if (list.size > maxItems) {
                list.subList(maxItems, list.size).clear()
            }
            save(list)
        }
    }

    fun updateStatus(id: String, status: TransferStatus, sha256: String = "") {
        synchronized(lock) {
            val list = load().toMutableList()
            val idx = list.indexOfFirst { it.id == id }
            if (idx >= 0) {
                val old = list[idx]
                list[idx] = old.copy(
                    status = status,
                    sha256 = if (sha256.isNotBlank()) sha256 else old.sha256,
                )
                save(list)
            }
        }
    }

    fun getHistory(): List<CoudropRecord> {
        synchronized(lock) {
            return load()
        }
    }

    fun clear() {
        synchronized(lock) {
            if (file.exists()) {
                file.delete()
            }
        }
    }

    fun remove(id: String) {
        synchronized(lock) {
            val list = load().toMutableList()
            list.removeAll { it.id == id }
            save(list)
        }
    }

    private fun load(): List<CoudropRecord> {
        if (!file.exists()) return emptyList()
        return runCatching {
            val text = file.readText(Charsets.UTF_8)
            val arr = JSONArray(text)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                CoudropRecord(
                    id = o.optString("id", ""),
                    name = o.optString("name", "file"),
                    size = o.optLong("size", 0L),
                    direction = runCatching { TransferDirection.valueOf(o.optString("direction")) }.getOrDefault(TransferDirection.INCOMING),
                    status = runCatching { TransferStatus.valueOf(o.optString("status")) }.getOrDefault(TransferStatus.COMPLETED),
                    timestampMs = o.optLong("timestampMs", System.currentTimeMillis()),
                    uriString = o.optString("uriString").takeIf { it.isNotBlank() },
                    mimeType = o.optString("mimeType", "application/octet-stream"),
                    sha256 = o.optString("sha256", ""),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun save(items: List<CoudropRecord>) {
        runCatching {
            val arr = JSONArray()
            for (item in items) {
                val o = JSONObject()
                o.put("id", item.id)
                o.put("name", item.name)
                o.put("size", item.size)
                o.put("direction", item.direction.name)
                o.put("status", item.status.name)
                o.put("timestampMs", item.timestampMs)
                o.put("uriString", item.uriString ?: "")
                o.put("mimeType", item.mimeType)
                o.put("sha256", item.sha256)
                arr.put(o)
            }
            file.writeText(arr.toString(), Charsets.UTF_8)
        }
    }
}
