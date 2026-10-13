package com.ringer.vault.credentials

import android.os.SystemClock
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/**
 * A login chosen in Ringer Vault's screen, on its way back to the
 * Credential Manager sheet as one entry, until the user taps it there.
 *
 * Only a random token goes into the entry's intent: intents pass through the
 * system and can outlive the request in its records. The password stays in
 * this process's memory, is handed over once, only to the same caller that
 * asked, and is dropped after two minutes if nobody comes for it.
 */
object CredentialHandoff {
    const val LIFETIME_MS = 2 * 60 * 1000L

    class Held(
        val caller: CredentialCaller,
        val username: String,
        val password: String,
        val at: Long,
    )

    /** For tests: the clock the lifetime is measured on. */
    @JvmStatic
    var clock: () -> Long = { SystemClock.elapsedRealtime() }

    private val held = ConcurrentHashMap<String, Held>()
    private val random = SecureRandom()

    fun put(caller: CredentialCaller, username: String, password: String): String {
        dropExpired()
        val token = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
        held[token] = Held(caller, username, password, clock())
        return token
    }

    /**
     * The login for [token], once, and only for [caller]. A second call, a
     * different caller or an expired token gets null; any call uses it up.
     */
    fun take(token: String?, caller: CredentialCaller?): Held? {
        dropExpired()
        if (token == null) return null
        val h = held.remove(token) ?: return null
        return if (caller != null && h.caller.sameAs(caller)) h else null
    }

    /** Everything, as when the vault locks. */
    fun clear() = held.clear()

    private fun dropExpired() {
        val now = clock()
        held.entries.removeIf { now - it.value.at > LIFETIME_MS }
    }
}
