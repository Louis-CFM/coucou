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
    val isPaused: Boolean = false,
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

    fun onAccept(accept: ServerMsg.DropAccept) {
        sender.onAccept(accept)
    }

    fun onAccept(transferId: String) {
        sender.onAccept(ServerMsg.DropAccept(transferId))
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

    fun pause(transferId: String) {
        sender.pause(transferId)
        receiver.pause(transferId)
        linkProvider()?.dropPause(transferId)
        activeMap[transferId]?.let { state ->
            val pausedRecord = state.record.copy(status = TransferStatus.PAUSED)
            activeMap[transferId] = state.copy(record = pausedRecord, isPaused = true, speedMBps = 0.0)
            _activeTransfers.value = HashMap(activeMap)
        }
    }

    fun resume(transferId: String) {
        sender.resume(transferId)
        receiver.resume(transferId)
        linkProvider()?.dropResume(transferId)
        activeMap[transferId]?.let { state ->
            val resumedRecord = state.record.copy(status = TransferStatus.IN_PROGRESS)
            activeMap[transferId] = state.copy(record = resumedRecord, isPaused = false)
            _activeTransfers.value = HashMap(activeMap)
        }
    }

    fun onRemotePause(transferId: String, origin: String = "windows") {
        sender.pause(transferId)
        receiver.pause(transferId)
        activeMap[transferId]?.let { state ->
            val pausedRecord = state.record.copy(status = TransferStatus.PAUSED)
            activeMap[transferId] = state.copy(record = pausedRecord, isPaused = true, speedMBps = 0.0)
            _activeTransfers.value = HashMap(activeMap)
        }
    }

    fun onRemoteResume(transferId: String, origin: String = "windows", offset: Long = 0L) {
        sender.resume(transferId)
        receiver.resume(transferId)
        activeMap[transferId]?.let { state ->
            val resumedRecord = state.record.copy(status = TransferStatus.IN_PROGRESS)
            activeMap[transferId] = state.copy(record = resumedRecord, isPaused = false)
            _activeTransfers.value = HashMap(activeMap)
        }
    }

    fun onRemoteCancel(transferId: String, reason: String = "cancelled", origin: String = "windows") {
        sender.onRemoteCancel(transferId, reason)
        receiver.onRemoteCancel(transferId, reason)
        activeMap.remove(transferId)
        _activeTransfers.value = HashMap(activeMap)
        historyStore.updateStatus(transferId, TransferStatus.CANCELLED)
        reloadHistory()
    }

    fun cancel(transferId: String) {
        sender.cancel(transferId)
        receiver.cancel(transferId)
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
