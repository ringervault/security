package com.ringer.vault.autofill

import android.content.Context
import java.security.SecureRandom

/**
 * Makes up a password for a sign-up or change-password form, as
 * lib/utils/password_generator.dart does in the app: the same character
 * sets, one of each kind in every password, and only the special characters
 * the user allowed in the app's generator. Nothing comes from the vault, so
 * no unlock is needed.
 */
object PasswordMaker {
    // Left out: l, I, 1, O, 0, which are misread when a password is typed
    // from a screen.
    private const val LOWER = "abcdefghijkmnopqrstuvwxyz"
    private const val UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    private const val DIGITS = "23456789"
    const val DEFAULT_SYMBOLS = "!@#\$%^&*-_=+?"
    const val LENGTH = 20

    /**
     * The special characters in [raw] a password can use: printable ASCII
     * that is neither a letter, a digit nor a space, each once.
     */
    fun cleanSymbols(raw: String): String {
        val out = StringBuilder()
        for (c in raw) {
            if (c.code in 0x21..0x7e && !c.isLetterOrDigit() && out.indexOf(c) < 0) out.append(c)
        }
        return out.toString()
    }

    fun make(
        allowedSymbols: String = DEFAULT_SYMBOLS,
        length: Int = LENGTH,
        random: SecureRandom = SecureRandom(),
    ): String {
        val special = cleanSymbols(allowedSymbols)
        val pools = listOfNotNull(LOWER, UPPER, DIGITS, special.takeIf { it.isNotEmpty() })
        // One of each kind first, so each is certain to be there.
        val chars = pools.map { it[random.nextInt(it.length)] }.toMutableList()
        val all = pools.joinToString("")
        while (chars.size < length) chars += all[random.nextInt(all.length)]
        for (i in chars.indices.reversed()) {
            val j = random.nextInt(i + 1)
            val t = chars[i]; chars[i] = chars[j]; chars[j] = t
        }
        return chars.joinToString("")
    }

    /**
     * The special characters allowed in the app's generator (kept by the
     * app's preferences as "generator.allowedSymbols"), or the usual set.
     */
    fun allowedSymbols(context: Context): String =
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.generator.allowedSymbols", null) ?: DEFAULT_SYMBOLS
}
