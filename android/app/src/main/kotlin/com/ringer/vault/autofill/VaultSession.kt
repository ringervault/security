package com.ringer.vault.autofill

import android.app.ActivityManager
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Whether the fingerprint may be offered, on the lock screen and at a
 * fill: only once the real vault has been unlocked with its PIN in this run
 * of the app, and not since the decoy was opened. The fingerprint opens the
 * real vault alone, so someone made to open the decoy must not be one touch
 * from it.
 *
 * Off until then, so a fresh start asks for the PIN first, as Android does
 * after a restart. That also means a missing fingerprint button says nothing:
 * it is missing after every start, not only after the decoy.
 *
 * Kept in memory and nowhere else: written down, it would say a decoy exists.
 */
object VaultSession {
    @Volatile
    var fingerprintAllowed: Boolean = false
        private set

    const val CHANNEL = "ringer_vault/session"

    /** Phones below this run the two unlock derivations one at a time. */
    private const val PARALLEL_MIN_BYTES = 2_500L * 1024 * 1024

    /**
     * A vault was opened. The decoy withdraws the fingerprint, and drops any
     * login kept for a next page or waiting for the sign-in sheet: someone
     * made to open the decoy must not find the real vault's login one tap
     * away. The real vault's PIN grants the fingerprint; the fingerprint
     * itself leaves it as it was.
     */
    fun unlocked(decoy: Boolean, byPin: Boolean) {
        if (decoy) {
            fingerprintAllowed = false
            dropHeldLogins()
        } else if (byPin) {
            fingerprintAllowed = true
        }
    }

    /**
     * A vault that was open has locked (auto-lock on leaving the app, the
     * timer, a panic shake, Strict Offline): nothing stays ready to fill.
     */
    fun locked() = dropHeldLogins()

    private fun dropHeldLogins() {
        NextStep.clear()
        com.ringer.vault.credentials.CredentialHandoff.clear()
    }

    /** Both engines (the app's and the autofill screen's) use it. */
    fun attach(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "unlocked" -> {
                        unlocked(
                            decoy = call.argument<Boolean>("decoy") == true,
                            byPin = call.argument<Boolean>("byPin") == true,
                        )
                        result.success(null)
                    }
                    // The vault locked: a login kept for the second page of
                    // a sign-in goes with it.
                    "locked" -> {
                        locked()
                        result.success(null)
                    }
                    "fingerprintAllowed" -> result.success(fingerprintAllowed)
                    // The lockout's clock: time since boot, which changing
                    // the phone's date and time does not move, and which
                    // boot this is, so a restart is noticed.
                    "clock" -> result.success(
                        mapOf(
                            "elapsedMs" to android.os.SystemClock.elapsedRealtime(),
                            "boot" to try {
                                android.provider.Settings.Global.getInt(
                                    app.contentResolver,
                                    android.provider.Settings.Global.BOOT_COUNT,
                                )
                            } catch (e: Exception) {
                                null
                            },
                        ),
                    )
                    // Two 32 MiB key derivations side by side is too much
                    // for a phone short of memory: Android may end the app
                    // mid-unlock, and an unlock that fails only on some
                    // paths would itself say something.
                    "lowMemory" -> {
                        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val info = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
                        result.success(am.isLowRamDevice || info.totalMem < PARALLEL_MIN_BYTES)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
