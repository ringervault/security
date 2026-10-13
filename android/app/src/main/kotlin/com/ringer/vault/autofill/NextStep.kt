package com.ringer.vault.autofill

import android.os.SystemClock

/**
 * The password half of a two-step sign-in (Amazon, Google, Microsoft): the
 * first page asks only for the username, the next for the password.
 *
 * When the user unlocks and picks an entry, it is filled and that entry's
 * password is kept here, in this process's memory only, for the page that
 * follows. There, the system's
 * suggestion is that login itself, filled with one tap and no second
 * unlock, instead of "Unlock Ringer Vault" again.
 *
 * It is the one exception to "every fill is unlocked for", so it is narrow:
 * the same app (package and signing certificate) and, in a browser verified
 * by its signature, the same address; for two minutes; and dropped as soon
 * as the vault locks (VaultSession "locked"), panic shake included. It is
 * offered, never filled on its own: Android fills nothing without a tap.
 */
object NextStep {
    const val LIFETIME_MS = 2 * 60 * 1000L

    class Held(
        val packageName: String,
        val certificateSha256: String,
        val webHost: String?,
        val label: String,
        val username: String?,
        val password: String,
        val at: Long,
    )

    @Volatile
    private var held: Held? = null

    /** For tests: the clock the lifetime is measured on. */
    @JvmStatic
    var clock: () -> Long = { SystemClock.elapsedRealtime() }

    fun remember(
        packageName: String,
        certificateSha256: String,
        webHost: String?,
        label: String,
        username: String?,
        password: String,
    ) {
        held = Held(
            packageName, certificateSha256.lowercase(), webHost?.lowercase(),
            label, username, password, clock(),
        )
    }

    /**
     * The login kept for this request, or null. [webHost] is the address a
     * verified browser reports, null for an app; it must be the same one.
     */
    fun matching(identity: RequestIdentity, webHost: String?): Held? {
        val h = held ?: return null
        if (clock() - h.at > LIFETIME_MS) {
            clear()
            return null
        }
        val sameCaller = h.packageName == identity.packageName &&
            h.certificateSha256 == identity.certificateSha256.lowercase()
        return if (sameCaller && sameSite(h.webHost, webHost?.lowercase())) h else null
    }

    /**
     * The same address, with or without "www.": a sign-in that moves from
     * amazon.in to www.amazon.in. Nothing looser. "One inside the other"
     * would also let www.amazon.co.uk match co.uk, a shared ending that is
     * no site at all, and siblings (pay.amazon.in) are other sites anyway.
     */
    private fun sameSite(kept: String?, now: String?): Boolean {
        if (kept == null || now == null) return kept == now
        return kept == now || kept == "www.$now" || now == "www.$kept"
    }

    fun clear() {
        held = null
    }
}
