package com.coucou.android.link

/** Things that should make the phone look at its link right away instead of waiting for the next timer. */
enum class Wake {
    /** The screen turned on or the phone was unlocked. */
    SCREEN_ON,
    SCREEN_OFF,
    /** The default network changed to a new one (Wi-Fi joined, Wi-Fi to mobile data...). */
    NEW_NETWORK,
    /** The network under the link went away. */
    NETWORK_LOST,
    /** The periodic alarm (KeepAlivePolicy). */
    ALARM,
}

/**
 * What to do on each [Wake]. Pure, so the rules are tests with fake events:
 *  - connected: ask the computer for a pong now (the connection may be half dead: asleep, or on a network that is gone);
 *  - not connected: reconnect now, but only if there is a network the link could use (Wi-Fi, or a relay over mobile data);
 *  - losing the network or turning the screen off needs nothing: the loop notices a dead connection by itself.
 */
object ReconnectPolicy {
    enum class Action { NONE, RETRY_NOW, CHECK_NOW }

    fun decide(event: Wake, paired: Boolean, connected: Boolean, wifiUp: Boolean, hasRelay: Boolean): Action {
        if (!paired) return Action.NONE
        return when (event) {
            Wake.SCREEN_OFF, Wake.NETWORK_LOST -> Action.NONE
            Wake.SCREEN_ON, Wake.NEW_NETWORK, Wake.ALARM ->
                when {
                    connected -> Action.CHECK_NOW
                    event == Wake.SCREEN_ON || wifiUp || hasRelay -> Action.RETRY_NOW
                    else -> Action.NONE
                }
        }
    }
}
