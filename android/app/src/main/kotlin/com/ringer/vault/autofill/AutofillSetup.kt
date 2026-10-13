package com.ringer.vault.autofill

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.autofill.AutofillManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Getting Ringer Vault chosen to fill: as Android's autofill service, and,
 * in Chrome, through "Autofill using another service".
 *
 * Android fills apps through one autofill service, picked in its settings.
 * Chrome (135 and later) fills web pages with its own password manager
 * unless the user picks that option in Chrome's settings, after which it
 * passes them to the Android service. Both screens belong to someone else,
 * so all this can do is say which one is still needed and open it.
 *
 * Whether Chrome's option is on can be read from Chrome too, but only with
 * the READ_USER_DICTIONARY permission, which Chrome uses to guard the
 * answer. That is not asked for: the row for Chrome says what to choose
 * rather than claiming to know.
 */
object AutofillSetup {
    private const val CHANNEL = "ringer_vault/autofill_setup"

    /** Chrome Stable first: the channel most people have. */
    private val CHROME_PACKAGES = listOf("com.android.chrome", "com.chrome.beta")

    fun attach(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(status(activity))
                "openAndroid" -> result.success(openAndroid(activity))
                "openChrome" -> result.success(openChrome(activity))
                "openCredentialProvider" -> result.success(openCredentialProvider(activity))
                else -> result.notImplemented()
            }
        }
    }

    private fun status(activity: Activity): Map<String, Any> {
        val autofill = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.getSystemService(AutofillManager::class.java)
        } else {
            null
        }
        return mapOf(
            "supported" to (autofill?.isAutofillSupported == true),
            // True only when this app's service is the one Android uses.
            "ours" to (autofill?.hasEnabledAutofillServices() == true),
            "chrome" to (installedChrome(activity) != null),
            // Credential Manager: Android 14 and later only.
            "credentialSupported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE),
            "credentialOurs" to credentialProviderEnabled(activity),
        )
    }

    private fun credentialProviderEnabled(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        return try {
            val manager = activity.getSystemService(android.credentials.CredentialManager::class.java)
            manager?.isEnabledCredentialProviderService(
                ComponentName(activity, "com.ringer.vault.credentials.VaultCredentialService"),
            ) == true
        } catch (_: Exception) {
            false
        }
    }

    /** Android's "Passwords, passkeys and accounts" screen, Ringer Vault proposed. */
    private fun openCredentialProvider(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        val intent = Intent(Settings.ACTION_CREDENTIAL_PROVIDER)
            .setData(Uri.parse("package:${activity.packageName}"))
        return start(activity, intent)
    }

    /** Android's own "choose an autofill service" screen, with Ringer Vault proposed. */
    private fun openAndroid(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val intent = Intent(Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE)
            .setData(Uri.parse("package:${activity.packageName}"))
        return start(activity, intent)
    }

    /**
     * Chrome's autofill settings, where "Autofill using another service" is.
     * The action and categories are exactly the ones Chrome answers to
     * (Android Developers blog, February 2025). False when Chrome is too old
     * to have the screen, or not installed.
     */
    private fun openChrome(activity: Activity): Boolean {
        val chrome = installedChrome(activity) ?: return false
        val intent = Intent(Intent.ACTION_APPLICATION_PREFERENCES)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .addCategory(Intent.CATEGORY_APP_BROWSER)
            .addCategory(Intent.CATEGORY_PREFERENCE)
            .setPackage(chrome)
        return start(activity, intent)
    }

    private fun installedChrome(activity: Activity): String? = CHROME_PACKAGES.firstOrNull {
        try {
            activity.packageManager.getPackageInfo(it, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun start(activity: Activity, intent: Intent): Boolean {
        if (intent.resolveActivity(activity.packageManager) == null) return false
        return try {
            activity.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}
