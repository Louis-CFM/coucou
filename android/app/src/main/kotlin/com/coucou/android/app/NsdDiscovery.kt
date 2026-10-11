package com.coucou.android.app

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.coucou.android.link.Discovery
import com.coucou.android.link.DiscoverySource
import com.coucou.android.link.Found
import java.net.Inet4Address

/**
 * Browses for `_coucou._tcp` with the framework's NsdManager (no library). A multicast lock is held only while
 * browsing and released the moment it stops. Services are resolved one at a time (NsdManager allows one resolve at a time);
 * what comes back is only what the computer announced: its name, an IPv4 address, the port and the short fingerprint id.
 * The caller decides if it is the paired computer, and checks the certificate; nothing here is trusted.
 */
class NsdDiscovery(context: Context) : DiscoverySource {
    private val app = context.applicationContext
    private val nsd = app.getSystemService(NsdManager::class.java)
    private val wifi = app.getSystemService(WifiManager::class.java)
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private var onFound: ((Found) -> Unit)? = null
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    @Synchronized
    override fun start(onFound: (Found) -> Unit) {
        stop()
        this.onFound = onFound
        lock = runCatching {
            wifi?.createMulticastLock("coucou-discovery")?.apply { setReferenceCounted(false); acquire() }
        }.getOrNull()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) { Log.d(TAG, "browsing") }
            override fun onServiceFound(info: NsdServiceInfo) { enqueue(info) }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) { Log.d(TAG, "browsing stopped") }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "browse failed: $errorCode"); stop() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "stop failed: $errorCode") }
        }
        listener = l
        try {
            nsd.discoverServices(Discovery.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.w(TAG, "cannot browse: ${e.javaClass.simpleName}")
            stop()
        }
    }

    @Synchronized
    override fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        onFound = null
        queue.clear()
        resolving = false
        runCatching { lock?.takeIf { it.isHeld }?.release() }
        lock = null
    }

    @Synchronized
    private fun enqueue(info: NsdServiceInfo) {
        if (listener == null) return
        queue.addLast(info)
        next()
    }

    @Synchronized
    @Suppress("DEPRECATION") // resolveService is deprecated from API 34; it still works and keeps one code path for API 30+
    private fun next() {
        if (resolving) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { done() }
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    toFound(serviceInfo)?.let { f -> synchronized(this@NsdDiscovery) { onFound }?.invoke(f) }
                    done()
                }
            })
        } catch (_: Exception) {
            done()
        }
    }

    @Synchronized
    private fun done() {
        resolving = false
        next()
    }

    @Suppress("DEPRECATION")
    private fun toFound(info: NsdServiceInfo): Found? {
        val host = (if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.filterIsInstance<Inet4Address>().firstOrNull() else info.host as? Inet4Address)
            ?.hostAddress ?: return null
        fun attr(k: String) = info.attributes[k]?.toString(Charsets.UTF_8)
        return Found(info.serviceName.orEmpty(), host, info.port, attr("fp"), attr("v"))
    }

    private companion object { const val TAG = "CoucouDiscovery" }
}
