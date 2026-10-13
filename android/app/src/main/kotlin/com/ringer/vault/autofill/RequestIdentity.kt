package com.ringer.vault.autofill

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest

/**
 * Who is asking for a credential.
 *
 * A package name is a claim: any app can be built with any package name that
 * is not already installed on the device. The signing certificate is proof,
 * because only the holder of the key can produce it. Every decision this
 * service makes is based on the fingerprint, never on the name alone.
 */
data class RequestIdentity(
    val packageName: String,
    val certificateSha256: String,
    val installedFromStore: Boolean,
    val isVerifiedBrowser: Boolean,
) {
    companion object {
        /** Play Store and the system installer are treated as store installs. */
        private val STORE_INSTALLERS = setOf(
            "com.android.vending",
            "com.google.android.feedback",
        )

        fun of(context: Context, packageName: String): RequestIdentity? {
            val pm = context.packageManager
            val history = signingCertificatesSha256(pm, packageName)
            val fingerprint = history.lastOrNull() ?: return null

            return RequestIdentity(
                packageName = packageName,
                certificateSha256 = fingerprint,
                installedFromStore = installerOf(pm, packageName) in STORE_INSTALLERS,
                // Any certificate in the verified rotation history: Android
                // lists a past one only when the app proved it rotated from
                // it, so a browser that moved to a new key stays known.
                isVerifiedBrowser = history.any { BrowserAllowlist.isVerifiedBrowser(packageName, it) },
            )
        }

        /**
         * The name the app shows under its icon, such as "Amazon Shopping".
         *
         * Used only to suggest which entries are likely to fit, never to
         * decide whether one may be filled: any app can call itself anything.
         */
        fun labelOf(context: Context, packageName: String): String? = try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        } catch (e: Exception) {
            null
        }

        /**
         * Lowercase hex SHA-256 of the app's signing certificates, oldest
         * first and the one it signs with now last.
         *
         * Android gives a rotated key's history with the original signer
         * first and the current one last, so the current one is the last.
         * That is the one an app is identified (and pinned) by: a rotation
         * then shows up as a change, which is what the pinning check is for.
         * An app with several signers at once gives its signers instead,
         * the first of which is used.
         */
        private fun signingCertificatesSha256(
            pm: PackageManager,
            packageName: String,
        ): List<String> = try {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(
                    packageName,
                    PackageManager.GET_SIGNING_CERTIFICATES,
                )
                info.signingInfo?.let {
                    if (it.hasMultipleSigners()) it.apkContentsSigners.take(1).toTypedArray()
                    else it.signingCertificateHistory
                }
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES).signatures?.take(1)?.toTypedArray()
            }

            signatures.orEmpty().map { signature ->
                MessageDigest.getInstance("SHA-256")
                    .digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(it) }
            }
        } catch (e: Exception) {
            emptyList()
        }

        private fun installerOf(pm: PackageManager, packageName: String): String? = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                pm.getInstallSourceInfo(packageName).installingPackageName
            } else {
                @Suppress("DEPRECATION")
                pm.getInstallerPackageName(packageName)
            }
        } catch (e: Exception) {
            null
        }
    }
}
