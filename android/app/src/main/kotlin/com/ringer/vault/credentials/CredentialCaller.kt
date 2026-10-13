package com.ringer.vault.credentials

import android.content.Context
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.credentials.provider.CallingAppInfo
import com.ringer.vault.autofill.BrowserAllowlist
import com.ringer.vault.autofill.RequestIdentity
import java.net.URI

/**
 * Who is asking Credential Manager for a login, by the same rules as the
 * autofill service (docs/CREDENTIAL_PROVIDER.md):
 *
 *  - the app, by its package and signing certificate, read by Android;
 *  - a web address only from a browser verified by its certificate, through
 *    Credential Manager's privileged-callers check;
 *  - a browser that is not verified: nobody, so nothing is offered;
 *  - any other app: that app, whatever page it shows.
 */
data class CredentialCaller(
    val identity: RequestIdentity,
    /** "https", or null for an app. */
    val webScheme: String?,
    /** The host a verified browser reports, or null for an app. */
    val webHost: String?,
    val knownBrowser: Boolean,
) {
    /** The same caller, for handing a chosen login back to it only. */
    fun sameAs(other: CredentialCaller): Boolean =
        identity.packageName == other.identity.packageName &&
            identity.certificateSha256.equals(other.identity.certificateSha256, ignoreCase = true) &&
            webHost.equals(other.webHost, ignoreCase = true)

    companion object {
        /** Null when nothing may be offered to this caller. */
        @RequiresApi(Build.VERSION_CODES.P)
        fun from(context: Context, info: CallingAppInfo): CredentialCaller? {
            val pkg = info.packageName
            if (pkg == context.packageName) return null

            // One signer, and the one Android has on record for this package:
            // the same fingerprint the autofill service pins.
            if (info.signingInfo.hasMultipleSigners()) return null
            val identity = RequestIdentity.of(context, pkg) ?: return null

            val browser = BrowserAllowlist.isBrowser(context, pkg)
            if (!identity.isVerifiedBrowser) {
                // An app is that app; a browser we cannot verify gets nothing.
                return if (browser) null else CredentialCaller(identity, null, null, knownBrowser = false)
            }

            // A verified browser: the page it is showing, as Android vouches.
            val origin = try {
                info.getOrigin(BrowserAllowlist.privilegedAppsJson())
            } catch (_: Exception) {
                null
            } ?: return null
            val (scheme, host) = parseOrigin(origin) ?: return null
            return CredentialCaller(identity, scheme, host, knownBrowser = true)
        }

        /**
         * "https://www.amazon.in" (with or without a trailing slash or a
         * port) as scheme and host, lowercase. Null for anything that is not
         * an http or https origin with a host.
         */
        fun parseOrigin(origin: String): Pair<String, String>? = try {
            val uri = URI(origin.trim())
            val scheme = uri.scheme?.lowercase()
            val host = uri.host?.lowercase()?.trimEnd('.')
            if ((scheme == "https" || scheme == "http") && !host.isNullOrEmpty()) scheme to host else null
        } catch (_: Exception) {
            null
        }
    }
}
