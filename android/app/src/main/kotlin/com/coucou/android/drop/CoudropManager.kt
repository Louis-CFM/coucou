package com.coucou.android.drop

import android.content.Context
import android.net.Uri
import com.coucou.android.link.DesktopLink
import com.coucou.android.link.ServerMsg
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

data class ActiveTransferUiState(
    val record: CoudropRecord,
    val progress: Float = 0f,
    val speedMBps: Double = 0.0,
    val error: String? = null,
)

/**
 * Top-level coordinator for Coudrop on Android: links Sender, Receiver, and HistoryStore with UI.
 */
class CoudropManager(
    private val context: Context,
    private val linkProvider: () -> DesktopLink?,
    val historyStore: CoudropHistoryStore = CoudropHistoryStore(context),
    val notifications: TransferNotificationManager = TransferNotificationManager(context),
) {
    private val _activeTransfers = MutableStateFlow<Map<String, ActiveTransferUiState>>(emptyMap())
    val activeTransfers: StateFlow<Map<String, ActiveTransferUiState>> = _activeTransfers.asStateFlow()

    private val _history = MutableStateFlow<List<CoudropRecord>>(emptyList())
    val history: StateFlow<List<CoudropRecord>> = _history.asStateFlow()

    private val activeMap = ConcurrentHashMap<String, ActiveTransferUiState>()

    val receiver = FileTransferReceiver(
        context = context,
        link = linkProvider,
        notifications = notifications,
        historyStore = historyStore,
        onTransferProgress = { record, progress ->
            val state = ActiveTransferUiState(record, progress)
            activeMap[record.id] = state
            _activeTransfers.value = HashMap(activeMap)
        },
        onTransferComplete = { record ->
            activeMap.remove(record.id)
            _activeTransfers.value = HashMap(activeMap)
            reloadHistory()
        },
        onTransferFailed = { id, _reason ->
            activeMap.remove(id)
            _activeTransfers.value = HashMap(activeMap)
            reloadHistory()
        },
    )
    val sender = FileTransferSender(context, linkProvider, notifications)

    init {
        reloadHistory()
    }

    fun reloadHistory() {
        _history.value = historyStore.getHistory()
    }

    fun sendUris(uris: List<Uri>) {
        sender.sendUris(
            uris = uris,
            onProgress = { record, progress, speed ->
                val state = ActiveTransferUiState(record, progress, speed)
                activeMap[record.id] = state
                _activeTransfers.value = HashMap(activeMap)
            },
            onComplete = { record ->
                activeMap.remove(record.id)
                _activeTransfers.value = HashMap(activeMap)
                historyStore.addRecord(record)
                reloadHistory()
            },
            onError = { id, err ->
                val existing = activeMap.remove(id)
                _activeTransfers.value = HashMap(activeMap)
                if (existing != null) {
                    val failedRecord = existing.record.copy(status = TransferStatus.FAILED)
                    historyStore.addRecord(failedRecord)
                    reloadHistory()
                }
            },
        )
    }

    fun onAccept(transferId: String) {
        sender.onAccept(transferId)
    }

    fun onReject(transferId: String, reason: String) {
        sender.onReject(transferId, reason)
        receiver.onCancel(ServerMsg.DropCancel(transferId, reason))
        activeMap.remove(transferId)
        _activeTransfers.value = HashMap(activeMap)
        historyStore.updateStatus(transferId, TransferStatus.FAILED)
        reloadHistory()
    }

    fun onDone(transferId: String, sha256: String) {
        sender.onDone(transferId, sha256)
        reloadHistory()
    }

    fun cancel(transferId: String) {
        sender.cancel(transferId)
        receiver.onCancel(ServerMsg.DropCancel(transferId, "cancelled"))
        activeMap.remove(transferId)
        _activeTransfers.value = HashMap(activeMap)
        historyStore.updateStatus(transferId, TransferStatus.CANCELLED)
        reloadHistory()
    }

    fun clearHistory() {
        historyStore.clear()
        reloadHistory()
    }

    fun removeHistoryItem(id: String) {
        historyStore.remove(id)
        reloadHistory()
    }
}
