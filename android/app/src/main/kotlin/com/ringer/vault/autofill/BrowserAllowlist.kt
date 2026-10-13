package com.ringer.vault.autofill

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build

/**
 * Browsers whose word about a web address is worth taking.
 *
 * On Android the web domain in a fill request is a string set by the app that
 * drew the screen. An app containing no browser at all can claim to be
 * showing a bank. Believing that claim is how credentials get handed to
 * whoever asked for them, so it is only accepted from a binary that has been
 * verified to be a browser by its signing certificate.
 *
 * An unknown browser is not blocked. Its claim is simply not trusted, and the
 * user is asked to confirm the address once, which is the same trade the app
 * makes everywhere else: refuse to decide silently, never refuse to work.
 */
object BrowserAllowlist {

    /**
     * Google's release signing certificate, which signs Chrome along with the
     * rest of Google's Android apps.
     *
     * Read from the APK of a real Chrome install (apksigner, 2026-09-29,
     * certificate DN "CN=Android, O=Google Inc."), not copied from a web
     * page. It is the long-published Google release key rather than a debug
     * key, which is what makes it safe to hard-code.
     */
    private const val GOOGLE_RELEASE =
        "f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83"

    /**
     * Known browsers and the lowercase hex SHA-256 of their signing
     * certificates.
     *
     * A fingerprint is only listed once it has been read from a real install.
     * The rest are left empty on purpose: inventing a value would silently
     * stop a genuine browser working, and an empty set simply means that
     * browser's claimed address is not auto-trusted, so the user confirms it
     * once. That is the safe direction to be incomplete in.
     */
    private val KNOWN_BROWSERS: Map<String, Set<String>> = mapOf(
        "com.android.chrome" to setOf(GOOGLE_RELEASE),
        "com.chrome.beta" to emptySet(),
        "org.mozilla.firefox" to emptySet(),
        "com.microsoft.emmx" to emptySet(),
        "com.brave.browser" to emptySet(),
        "com.sec.android.app.sbrowser" to emptySet(),
        "com.duckduckgo.mobile.android" to emptySet(),
        "com.opera.browser" to emptySet(),
        "com.vivaldi.browser" to emptySet(),
    )

    fun isKnownBrowserPackage(packageName: String): Boolean =
        KNOWN_BROWSERS.containsKey(packageName)

    /**
     * Whether [packageName] is a browser: listed above, or able to open any
     * web address at all (one no app could claim as its own link).
     *
     * An app that shows its sign-in as a web page, such as Amazon's, is
     * treated as that app, and a first fill pins the app. A browser must
     * never be pinned that way, or the entry would be offered on every site
     * it shows. Browsers not listed above are caught here: they declare that
     * they open web links in general, which an app opening only its own
     * site's links does not.
     */
    fun isBrowser(context: Context, packageName: String): Boolean {
        if (isKnownBrowserPackage(packageName)) return true
        val anyPage = Intent(Intent.ACTION_VIEW, Uri.parse("https://example.invalid/"))
            .addCategory(Intent.CATEGORY_BROWSABLE)
        return try {
            val pm = context.packageManager
            val handlers = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.queryIntentActivities(anyPage, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.queryIntentActivities(anyPage, PackageManager.MATCH_ALL)
            }
            handlers.any { it.activityInfo?.packageName == packageName }
        } catch (_: Exception) {
            // Unsure: a browser is the safe answer, its address is refused.
            true
        }
    }

    /**
     * The browsers above with a known certificate, in the form Credential
     * Manager takes for "privileged" callers: only these may tell a
     * credential provider which web origin is asking (CallingAppInfo.getOrigin).
     * Built from the same list, so the provider and the autofill service
     * believe exactly the same browsers.
     */
    fun privilegedAppsJson(): String {
        val apps = KNOWN_BROWSERS.filterValues { it.isNotEmpty() }.map { (pkg, fingerprints) ->
            val signatures = fingerprints.joinToString(",") { fp ->
                val colons = fp.uppercase().chunked(2).joinToString(":")
                "{\"build\":\"release\",\"cert_fingerprint_sha256\":\"$colons\"}"
            }
            "{\"type\":\"android\",\"info\":{\"package_name\":\"$pkg\",\"signatures\":[$signatures]}}"
        }
        return "{\"apps\":[${apps.joinToString(",")}]}"
    }

    fun isVerifiedBrowser(packageName: String, certificateSha256: String): Boolean {
        val fingerprints = KNOWN_BROWSERS[packageName] ?: return false
        return fingerprints.contains(certificateSha256.lowercase())
    }
}
