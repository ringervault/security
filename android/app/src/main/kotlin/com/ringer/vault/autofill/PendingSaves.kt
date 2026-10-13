package com.ringer.vault.autofill

import android.os.SystemClock
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/** A login the user typed into another app, waiting to be saved. */
data class PendingSave(
    val username: String?,
    val password: String,
)

/**
 * Hands a typed login from the autofill service to the save screen.
 *
 * Only a random token travels in the intent. Intent extras pass through the
 * system's activity manager and can outlive the request in its records; the
 * password itself stays in this process's memory, is handed over once, and
 * is dropped after a few minutes if nobody comes for it.
 */
object PendingSaves {
    private const val LIFETIME_MS = 5 * 60 * 1000L

    private class Held(val save: PendingSave, val at: Long)

    private val held = ConcurrentHashMap<String, Held>()
    private val random = SecureRandom()

    fun put(save: PendingSave): String {
        dropExpired()
        val bytes = ByteArray(16).also(random::nextBytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        held[token] = Held(save, SystemClock.elapsedRealtime())
        return token
    }

    /** The login for [token], once. A second call gets null. */
    fun take(token: String?): PendingSave? {
        dropExpired()
        if (token == null) return null
        return held.remove(token)?.save
    }

    private fun dropExpired() {
        val now = SystemClock.elapsedRealtime()
        held.entries.removeIf { now - it.value.at > LIFETIME_MS }
    }
}
