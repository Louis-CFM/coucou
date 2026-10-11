package com.coucou.android.link

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.SSLContext

enum class LinkState { DISCONNECTED, CONNECTING, CONNECTED }

/** Why a link that had been working ended, as far as the phone can tell. */
enum class LostReason {
    /** Nothing came back: the read timed out or a liveness check got no answer (typical after the phone slept). */
    SILENT,
    /** The computer closed the connection (it restarted, or dropped a connection that had been silent for too long). */
    CLOSED,
    /** The network under it failed (reset, unreachable, Wi-Fi changed). */
    NETWORK,
}

interface LinkListener {
    fun onState(state: LinkState) {}
    fun onWelcome(desktopName: String, os: String) {}
    /** The optional features this computer offers right now (after the welcome). */
    fun onCaps(caps: Set<String>) {}
    fun onSessions(sessions: List<SessionInfo>) {}
    fun onApproval(request: ApprovalRequest) {}
    fun onApprovalResolved(fingerprint: String) {}
    /** A question to answer (only with the `answers` capability). It is removed by [onApprovalResolved] with the same fingerprint. */
    fun onQuestion(request: QuestionRequest) {}
    /** What Mochi wears on the computer: "auto" or an outfit (only with the `prefs` capability). */
    fun onPrefs(outfit: String) {}
    /** A part of a file's diff the phone asked for (only with the `diffs` capability). */
    fun onDiff(part: ServerMsg.Diff) {}
    /** The plan usage (only with the `usage` capability); both plans null: nothing to show any more. */
    fun onUsage(usage: UsageSnapshot) {}
    /** The service cards (only with the `services` capability); an empty list: none to show any more. */
    fun onServices(cards: List<ServiceCard>) {}
    /** The relay's access key was replaced on the computer (only with the `relay` capability). */
    fun onRelayAccess(access: String) {}
    fun onError(code: String, message: String) {}
    /** A connection attempt failed before the computer answered; [consecutive] counts the failures in a row (1 for the first). */
    fun onConnectFailed(consecutive: Int) {}
    /** A link that had been working ended without the user asking for it (not for a wrong token or version: see [onError]). */
    fun onLinkLost(reason: LostReason) {}
    fun onChatModels(models: List<ChatModel>) {}
    fun onChatDelta(id: String, text: String) {}
    fun onChatDone(id: String, text: String?) {}
    fun onChatError(id: String, reason: String, message: String) {}
}

/** What the UI talks to: the real [LinkClient] or the offline [DemoLink]. */
interface DesktopLink {
    val approvals: ApprovalBook
    fun start()
    fun stop()
    /** Try the connection again now (the network changed); the demo has nothing to retry. */
    fun retryNow() {}
    /**
     * Is the link alive right now? Connected: asks the computer for a pong and drops the connection (so it reconnects) if none
     * comes in time. Not connected: reconnects at once. Called when the screen turns on, when a network appears, and by the alarm.
     */
    fun checkNow() {}
    /** allow/deny for a pending approval; false if unknown, expired, already decided or not connected. */
    fun decide(fingerprint: String, allow: Boolean): Boolean

    /** Sends the picks for a question; false if the link is down or the computer did not offer `answers`. */
    fun answer(fingerprint: String, picks: List<List<String>>): Boolean = false

    /** Asks for the lines of a file in a session's list; false if the link is down or the computer did not offer `diffs`. */
    fun getDiff(pillId: String, fileId: Long): Boolean = false

    // Chat through the computer (docs/ANDROID_LINK.md). Not offered by the demo.
    fun chatModels() {}
    /** False if the link is down; the answer arrives through the listener. */
    fun chatSend(id: String, model: String, text: String): Boolean = false
    fun chatCancel(id: String) {}
    fun chatReset() {}
}

/** Opens the (TLS) connection to the desktop. Swappable so tests can use plain sockets. */
fun interface Connector { fun connect(timeoutMs: Int): Socket }

object PinnedTls {
    private const val HANDSHAKE_TIMEOUT_MS = 10_000

    fun connector(p: PairingPayload) = Connector { timeoutMs ->
        val ctx = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(PinnedTrustManager(p.certSha256)), SecureRandom())
        }
        val raw = Socket()
        raw.connect(InetSocketAddress(p.host, p.port), timeoutMs)
        val tls = ctx.socketFactory.createSocket(raw, p.host, p.port, true) as javax.net.ssl.SSLSocket
        tls.enabledProtocols = tls.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }.toTypedArray()
        tls.soTimeout = HANDSHAKE_TIMEOUT_MS // the TCP connect above is quick (a wrong address must fail fast); the handshake gets longer
        tls.startHandshake()
        tls
    }
}

/**
 * Background connection to one paired desktop: hello, then messages until the link drops, then
 * reconnect with backoff. Plain threads, no coroutines, no polling: the thread blocks on the
 * socket, so an idle link costs no CPU. Listener callbacks arrive on the link thread.
 */
class LinkClient(
    private val pairing: PairingPayload,
    private val deviceName: String,
    private val listener: LinkListener,
    private val connector: Connector = PinnedTls.connector(pairing),
    private val clockMs: () -> Long = System::currentTimeMillis,
    private val readTimeoutMs: Int = 60_000,
    private val pingEveryMs: Long = 20_000,
    private val backoffMs: LongArray = longArrayOf(1_000, 2_000, 4_000, 8_000, 16_000, 30_000),
    /** The optional features asked for in the hello; empty is what an app without them sends. */
    private val caps: List<String> = Protocol.CAPABILITIES,
    /** How long the saved address gets to accept the connection before it counts as a failure (then the network is searched). */
    private val connectTimeoutMs: Int = DiscoveryPolicy.SAVED_CONNECT_TIMEOUT_MS,
    /** How long a liveness check ([checkNow]) waits for any answer before it gives the connection up. */
    private val pongWaitMs: Long = 8_000,
) : DesktopLink {
    override val approvals = ApprovalBook(clockMs)

    @Volatile private var running = false
    /** Set by an auth or version error: retrying with the same pairing can never work. */
    @Volatile private var fatal = false
    /** The computer's welcome offered `answers` on this connection. */
    @Volatile private var answersOffered = false
    /** The computer's welcome offered `prefs` on this connection. */
    @Volatile private var prefsOffered = false
    /** The computer's welcome offered `diffs` on this connection. */
    @Volatile private var diffsOffered = false
    /** The computer's welcome offered `usage` on this connection. */
    @Volatile private var usageOffered = false
    /** The computer's welcome offered `services` on this connection. */
    @Volatile private var servicesOffered = false
    /** The computer's welcome offered `relay` on this connection. */
    @Volatile private var relayOffered = false
    @Volatile private var socket: Socket? = null
    /** When the last line arrived (the clock of [clockMs]); a liveness check compares it with the moment it asked. */
    @Volatile private var lastInboundMs = 0L
    /** Set when a liveness check closed the socket itself, so the loss is reported as silence, not as a network error. */
    @Volatile private var probeKilled = false
    @Volatile private var out: OutputStream? = null
    @Volatile private var thread: Thread? = null
    private val writeLock = Any()
    /** Released by [retryNow] to cut a backoff wait short (the network changed). */
    private val wake = java.util.concurrent.Semaphore(0)
    /** Android forbids network I/O on the main thread, and the UI calls decide() and stop(): writes happen here. */
    @Volatile private var writer: ExecutorService? = null

    @Synchronized override fun start() {
        if (running) return
        running = true
        fatal = false
        writer = Executors.newSingleThreadExecutor { r -> Thread(r, "coucou-link-writer").apply { isDaemon = true } }
        thread = Thread(::loop, "coucou-link").apply { isDaemon = true; start() }
    }

    @Synchronized override fun stop() {
        running = false
        val s = socket
        // Sent and closed off the caller's thread; "bye" is best effort.
        writer?.let { w ->
            runCatching { w.execute { runCatching { send(ClientMsg.Bye) }; runCatching { s?.close() } } }
            w.shutdown()
        } ?: runCatching { s?.close() }
        writer = null
        thread?.interrupt()
        thread = null
    }

    /** Try again now instead of waiting out the backoff: the network changed, or a new address was found. */
    override fun retryNow() { wake.release() }

    override fun checkNow() {
        if (!running) return
        val s = socket
        if (out == null || s == null) { wake.release(); return } // not connected: do not wait out the backoff
        val asked = clockMs()
        if (!queue(ClientMsg.Ping)) return
        // Any line that arrives after the question proves the connection works. If none does, it is half-dead
        // (the phone slept, the Wi-Fi changed): close it, and the loop reconnects.
        Thread({
            try {
                Thread.sleep(pongWaitMs)
                if (running && socket === s && lastInboundMs < asked) {
                    probeKilled = true
                    runCatching { s.close() }
                }
            } catch (_: InterruptedException) { }
        }, "coucou-link-check").apply { isDaemon = true; start() }
    }

    /** Sends allow/deny for a pending approval. False if it is unknown, expired, decided or the link is down. */
    override fun decide(fingerprint: String, allow: Boolean): Boolean {
        val w = writer
        if (out == null || w == null) return false
        val age = approvals.ageMs(fingerprint) ?: 0L
        val request = approvals.claim(fingerprint) ?: return false
        // If it cannot be sent it goes back with the time it has already used, not a fresh 120 s.
        val back = { approvals.restore(request, clockMs() - age) }
        return try {
            w.execute {
                try {
                    send(ClientMsg.Decision(request.fingerprint, allow))
                } catch (_: IOException) {
                    back() // not sent: keep it so the user can retry while it is still valid
                    listener.onError("send", "could not reach the desktop")
                }
            }
            true
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            back()
            false
        }
    }

    /** Queues a message on the writer thread (never on the caller's: it may be the main thread). */
    private fun queue(m: ClientMsg): Boolean {
        val w = writer
        if (out == null || w == null) return false
        return try {
            w.execute { try { send(m) } catch (_: IOException) { listener.onError("send", "could not reach the desktop") } }
            true
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            false
        }
    }

    /** Asks for the lines of a file of the session list. False if the computer did not offer `diffs` or the link is down. */
    override fun getDiff(pillId: String, fileId: Long): Boolean =
        diffsOffered && Protocol.CAP_DIFFS in caps && queue(ClientMsg.GetDiff(pillId, fileId))

    override fun answer(fingerprint: String, picks: List<List<String>>): Boolean =
        answersOffered && Protocol.CAP_ANSWERS in caps && queue(ClientMsg.Answer(fingerprint, picks))

    override fun chatModels() { queue(ClientMsg.ChatModels) }
    override fun chatSend(id: String, model: String, text: String) = queue(ClientMsg.ChatSend(id, model, text))
    override fun chatCancel(id: String) { queue(ClientMsg.ChatCancel(id)) }
    override fun chatReset() { queue(ClientMsg.ChatReset) }

    private fun send(m: ClientMsg) {
        val o = out ?: throw IOException("not connected")
        synchronized(writeLock) {
            o.write((Wire.encode(m) + "\n").toByteArray(Charsets.UTF_8))
            o.flush()
        }
    }

    private fun loop() {
        var attempt = 0
        while (running) {
            listener.onState(LinkState.CONNECTING)
            var connectedOnce = false
            var lost: LostReason? = null
            probeKilled = false
            try {
                val s = connector.connect(connectTimeoutMs)
                socket = s
                s.soTimeout = readTimeoutMs
                s.tcpNoDelay = true
                // The system's own probe of a silent connection; its default delay is long, so the real liveness
                // checks are the app's pings and checkNow(). It costs nothing and catches a connection the network dropped.
                runCatching { s.keepAlive = true }
                lastInboundMs = clockMs()
                out = s.getOutputStream()
                send(ClientMsg.Hello(Protocol.VERSION, pairing.token, deviceName, caps))
                val pinger = startPinger()
                try {
                    read(BufferedInputStream(s.getInputStream())) { connectedOnce = true }
                } finally {
                    pinger.interrupt()
                }
            } catch (e: java.net.SocketTimeoutException) {
                lost = LostReason.SILENT
            } catch (_: IOException) {
                lost = LostReason.NETWORK
            } catch (_: InterruptedException) {
                // stop() was called
            } finally {
                out = null
                answersOffered = false
                prefsOffered = false
                diffsOffered = false
                usageOffered = false
                servicesOffered = false
                relayOffered = false
                runCatching { socket?.close() }
                socket = null
                approvals.clear()
            }
            if (fatal) running = false
            if (!running) break
            // A link that had been working and ended on its own: say why (a clean end of the stream is the computer closing it).
            if (connectedOnce) listener.onLinkLost(if (probeKilled) LostReason.SILENT else lost ?: LostReason.CLOSED)
            listener.onState(LinkState.DISCONNECTED)
            if (connectedOnce) attempt = 0 else listener.onConnectFailed(attempt + 1)
            val wait = backoffMs[minOf(attempt, backoffMs.size - 1)]
            attempt++
            wake.drainPermits()
            try { wake.tryAcquire(wait, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { break }
        }
        listener.onState(LinkState.DISCONNECTED)
    }

    private fun startPinger() = Thread({
        try {
            while (true) {
                Thread.sleep(pingEveryMs)
                send(ClientMsg.Ping)
            }
        } catch (_: Exception) {
            // interrupted or link closed: the reader notices on its own
        }
    }, "coucou-link-ping").apply { isDaemon = true; start() }

    private fun read(input: InputStream, onFirstMessage: () -> Unit) {
        var first = true
        while (running) {
            val line = readLine(input) ?: return
            lastInboundMs = clockMs()
            val msg = Wire.decodeServer(line) ?: continue
            if (first) { first = false; onFirstMessage() }
            when (msg) {
                is ServerMsg.Welcome -> {
                    if (msg.version != Protocol.VERSION) { listener.onError("version", "desktop speaks v${msg.version}"); fatal = true; return }
                    // Stored before anyone is told, so a listener that reacts to the welcome can already use what was offered.
                    answersOffered = Protocol.CAP_ANSWERS in msg.caps
                    prefsOffered = Protocol.CAP_PREFS in msg.caps
                    diffsOffered = Protocol.CAP_DIFFS in msg.caps
                    usageOffered = Protocol.CAP_USAGE in msg.caps
                    servicesOffered = Protocol.CAP_SERVICES in msg.caps
                    relayOffered = Protocol.CAP_RELAY in msg.caps
                    listener.onState(LinkState.CONNECTED)
                    listener.onWelcome(msg.desktopName, msg.os)
                    listener.onCaps(msg.caps)
                    // Told what it may use right away, so the Chat screen has its list when it opens.
                    if (Protocol.CAP_CHAT in msg.caps && Protocol.CAP_CHAT in caps) queue(ClientMsg.ChatModels)
                }
                is ServerMsg.Sessions -> listener.onSessions(msg.sessions)
                is ServerMsg.Approval -> { approvals.add(msg.request); listener.onApproval(msg.request) }
                is ServerMsg.ApprovalResolved -> { approvals.resolve(msg.fingerprint); listener.onApprovalResolved(msg.fingerprint) }
                // Only offered to a phone that asked and was offered `answers`; ignored from a computer that did not.
                is ServerMsg.Question -> if (answersOffered && Protocol.CAP_ANSWERS in caps) listener.onQuestion(msg.request)
                // Only after the phone asked for it, and only on a connection that was offered `diffs`.
                is ServerMsg.Diff -> if (diffsOffered && Protocol.CAP_DIFFS in caps) listener.onDiff(msg)
                is ServerMsg.Services -> if (servicesOffered && Protocol.CAP_SERVICES in caps) listener.onServices(msg.cards)
                is ServerMsg.Usage -> if (usageOffered && Protocol.CAP_USAGE in caps) listener.onUsage(msg.usage)
                // Only on a connection that was offered `relay`, and only a well-formed key.
                is ServerMsg.RelayAccess -> if (relayOffered && Protocol.CAP_RELAY in caps) listener.onRelayAccess(msg.access)
                is ServerMsg.Prefs -> if (prefsOffered && Protocol.CAP_PREFS in caps) listener.onPrefs(msg.outfit)
                ServerMsg.Pong -> {}
                is ServerMsg.ChatModels -> listener.onChatModels(msg.models)
                is ServerMsg.ChatDelta -> listener.onChatDelta(msg.id, msg.text)
                is ServerMsg.ChatDone -> listener.onChatDone(msg.id, msg.text)
                is ServerMsg.ChatError -> listener.onChatError(msg.id, msg.reason, msg.message)
                is ServerMsg.Error -> { listener.onError(msg.code, msg.message); if (msg.code == "auth") { fatal = true; return } }
            }
        }
    }

    /** Reads one '\n'-terminated line; null at end of stream. Throws if a line passes the size limit. */
    private fun readLine(input: InputStream): String? {
        val buf = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b < 0) return null
            if (b == '\n'.code) return String(buf.toByteArray(), Charsets.UTF_8)
            if (buf.size() >= Protocol.MAX_LINE_BYTES) throw IOException("line too long")
            buf.write(b)
        }
    }
}
