package com.ringer.vault.autofill

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.ringer.vault.R
import io.flutter.embedding.android.FlutterActivityLaunchConfigs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import androidx.credentials.CreatePasswordRequest
import androidx.credentials.CreatePasswordResponse
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPasswordOption
import androidx.credentials.provider.PasswordCredentialEntry
import androidx.credentials.provider.PendingIntentHandler
import com.ringer.vault.credentials.CredentialCaller
import com.ringer.vault.credentials.CredentialHandoff
import com.ringer.vault.credentials.CredentialPickActivity

/**
 * The activity behind the "Unlock Ringer Vault" row.
 *
 * It runs the app's own Dart code, so unlocking uses the same Argon2id and
 * the same envelopes as everywhere else. Nothing about the vault format is
 * reimplemented here: this class only translates between Dart and the
 * autofill framework.
 */
@RequiresApi(Build.VERSION_CODES.O)
class AutofillUnlockActivity : FlutterFragmentActivity() {

    private var usernameId: AutofillId? = null
    private var passwordId: AutofillId? = null

    /** True when this launch attached to an engine that was already running. */
    private var reusedEngine = false

    private var channel: MethodChannel? = null

    /** A login to save rather than fill, taken from [PendingSaves] once. */
    private var pendingSave: PendingSave? = null

    /**
     * Which surface opened this screen: the autofill row, or the Credential
     * Manager sheet (to fill, or to save). The rules are the same; only how
     * the answer goes back differs (docs/CREDENTIAL_PROVIDER.md).
     */
    private var mode: String = MODE_AUTOFILL

    /** For the sheet: who is asking, as Android vouches (null otherwise). */
    private var credentialCaller: CredentialCaller? = null

    /** For the sheet: the password request the entry handed back answers. */
    private var passwordOption: BeginGetPasswordOption? = null

    /**
     * Reads who is asking from the system's own request, for a launch from
     * the Credential Manager sheet. False when nothing may be answered.
     */
    private fun readCredentialRequest(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return false
        return when (mode) {
            MODE_CREDENTIAL_GET -> {
                val request = PendingIntentHandler.retrieveBeginGetCredentialRequest(intent)
                credentialCaller = request?.callingAppInfo?.let { CredentialCaller.from(this, it) }
                passwordOption = request?.beginGetCredentialOptions
                    ?.filterIsInstance<BeginGetPasswordOption>()?.firstOrNull()
                credentialCaller != null && passwordOption != null
            }
            MODE_CREDENTIAL_CREATE -> {
                val request = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
                credentialCaller = request?.callingAppInfo?.let { CredentialCaller.from(this, it) }
                val create = request?.callingRequest as? CreatePasswordRequest
                if (create != null && create.password.isNotEmpty()) {
                    pendingSave = PendingSave(create.id.takeIf { it.isNotBlank() }, create.password)
                }
                credentialCaller != null && pendingSave != null
            }
            else -> false
        }
    }

    /**
     * Keeps one Flutter engine alive across fills.
     *
     * Without this, every login screen means a fresh engine, a fresh isolate,
     * and typing the whole master secret again, which is how an autofill
     * feature ends up switched off. The engine holds the unlock for a few
     * minutes; the encrypted database itself is closed between fills, so the
     * vault stays available to the main app in the meantime.
     *
     * The engine goes into Flutter's engine cache and this activity names it
     * by [getCachedEngineId]. Handing the engine over from
     * provideFlutterEngine instead looks equivalent, but Flutter then
     * destroys it when the screen closes, whatever
     * [shouldDestroyEngineWithHost] says, and the next login screen crashed
     * attaching to the dead engine.
     */
    private fun ensureEngine() {
        val cache = FlutterEngineCache.getInstance()
        if (cache.contains(ENGINE_ID)) {
            reusedEngine = true
            return
        }

        reusedEngine = false
        val engine = FlutterEngine(applicationContext)
        engine.navigationChannel.setInitialRoute(ROUTE)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )
        // Belt and braces: an engine destroyed for any other reason (low
        // memory, say) leaves the cache, so it is never handed out again.
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {}
            override fun onEngineWillDestroy() {
                if (cache.get(ENGINE_ID) === engine) cache.remove(ENGINE_ID)
            }
        })
        cache.put(ENGINE_ID, engine)
    }

    override fun getCachedEngineId(): String = ENGINE_ID

    /**
     * See-through, so the sheet Flutter draws sits over the app being
     * signed in to rather than replacing it on screen.
     */
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    /** The engine outlives this activity on purpose. */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before super.onCreate, which is where Flutter looks the engine up
        // and where a reused engine is told about this request.
        usernameId = intentExtraAutofillId(EXTRA_USERNAME_ID)
        passwordId = intentExtraAutofillId(EXTRA_PASSWORD_ID)
        pendingSave = PendingSaves.take(intent.getStringExtra(EXTRA_SAVE_TOKEN))
        mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_AUTOFILL
        val answerable = mode == MODE_AUTOFILL || readCredentialRequest()
        ensureEngine()
        super.onCreate(savedInstanceState)
        if (!answerable) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        // Same rule as the rest of the app: nothing showing a secret may be
        // screenshotted or appear in the recents preview.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )
    }

    override fun getInitialRoute(): String = ROUTE

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Re-registering replaces the previous handler, which matters: the
        // closure below captures this activity, and a reused engine would
        // otherwise still be answering the activity that has already gone.
        VaultSession.attach(flutterEngine, this)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRequest" -> result.success(requestDetails())
                    "fill" -> {
                        val username = call.argument<String>("username")
                        val password = call.argument<String>("password")
                        val label = call.argument<String>("label") ?: ""
                        finishWithDataset(label, username, password)
                        result.success(true)
                    }
                    "saved" -> {
                        if (mode == MODE_CREDENTIAL_CREATE &&
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
                        ) {
                            val reply = Intent()
                            PendingIntentHandler.setCreateCredentialResponse(reply, CreatePasswordResponse())
                            setResult(RESULT_OK, reply)
                        } else {
                            setResult(RESULT_OK)
                        }
                        finish()
                        result.success(true)
                    }
                    "cancel" -> {
                        setResult(RESULT_CANCELED)
                        finish()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // A fresh engine runs the screen from the top on its own. A reused one
        // is still showing the last request, so it has to be told.
        if (reusedEngine) channel?.invokeMethod("newRequest", null)
    }


    /**
     * Everything Dart needs to decide whether this request may be answered.
     * It is passed across as data, never as a decision already made.
     */
    private fun requestDetails(): Map<String, Any?> {
        val caller = credentialCaller
        if (caller != null) return credentialDetails(caller)
        return autofillDetails()
    }

    /** The sheet's caller, in the same shape as an autofill request. */
    private fun credentialDetails(caller: CredentialCaller): Map<String, Any?> = mapOf(
        "packageName" to caller.identity.packageName,
        "certificateSha256" to caller.identity.certificateSha256,
        "webDomain" to caller.webHost,
        "webScheme" to caller.webScheme,
        "knownBrowser" to caller.knownBrowser,
        "installedFromStore" to caller.identity.installedFromStore,
        "fromVerifiedBrowser" to caller.identity.isVerifiedBrowser,
        "compatibilityMode" to false,
        "hasUsernameField" to true,
        "hasPasswordField" to true,
        "appLabel" to RequestIdentity.labelOf(this, caller.identity.packageName),
        "typedUsername" to null,
        "save" to pendingSave?.let { mapOf("username" to it.username, "password" to it.password) },
    )

    private fun autofillDetails(): Map<String, Any?> = mapOf(
        "packageName" to intent.getStringExtra(EXTRA_PACKAGE),
        "certificateSha256" to intent.getStringExtra(EXTRA_CERTIFICATE),
        "webDomain" to intent.getStringExtra(EXTRA_WEB_DOMAIN),
        "webScheme" to intent.getStringExtra(EXTRA_WEB_SCHEME),
        "knownBrowser" to intent.getBooleanExtra(EXTRA_KNOWN_BROWSER, false),
        "installedFromStore" to intent.getBooleanExtra(EXTRA_FROM_STORE, true),
        "fromVerifiedBrowser" to intent.getBooleanExtra(EXTRA_VERIFIED_BROWSER, false),
        "compatibilityMode" to intent.getBooleanExtra(EXTRA_COMPATIBILITY_MODE, false),
        "hasUsernameField" to (usernameId != null),
        "hasPasswordField" to (passwordId != null),
        "appLabel" to intent.getStringExtra(EXTRA_APP_LABEL),
        "typedUsername" to intent.getStringExtra(EXTRA_TYPED_USERNAME),
        "save" to pendingSave?.let {
            mapOf("username" to it.username, "password" to it.password)
        },
    )

    /**
     * For the sheet: the chosen login goes back as one entry, its password
     * waiting in [CredentialHandoff] under a one-time token for the tap.
     */
    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private fun finishWithCredentialEntry(label: String, username: String?, password: String?) {
        val caller = credentialCaller
        val option = passwordOption
        if (caller == null || option == null || password.isNullOrEmpty()) {
            setResult(RESULT_CANCELED)
            finish()
            return
        }
        val user = username.orEmpty()
        // The next page of the sign-in, in the dropdown (NextStep).
        NextStep.remember(
            caller.identity.packageName, caller.identity.certificateSha256,
            caller.webHost, label, user, password,
        )
        val token = CredentialHandoff.put(caller, user, password)
        val pick = PendingIntent.getActivity(
            this, token.hashCode(),
            Intent(this, CredentialPickActivity::class.java)
                .putExtra(CredentialPickActivity.EXTRA_TOKEN, token),
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val entry = PasswordCredentialEntry.Builder(this, user.ifEmpty { label }, pick, option)
            .setDisplayName(label)
            .build()
        val reply = Intent()
        PendingIntentHandler.setBeginGetCredentialResponse(
            reply,
            BeginGetCredentialResponse.Builder().addCredentialEntry(entry).build(),
        )
        setResult(RESULT_OK, reply)
        finish()
    }

    private fun finishWithDataset(label: String, username: String?, password: String?) {
        if (mode == MODE_CREDENTIAL_GET && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            finishWithCredentialEntry(label, username, password)
            return
        }
        // Kept for the page that follows (NextStep): the password page of a
        // two-step sign-in, or the same page shown again after a mistake.
        // After every fill, not only a username-only page: a sign-in page
        // can carry a hidden password box of its own, which made the first
        // page look like a whole login and kept nothing. An address counts
        // only from a verified browser; from anything else the request is
        // the app's own.
        if (!password.isNullOrEmpty()) {
            val pkg = intent.getStringExtra(EXTRA_PACKAGE)
            val cert = intent.getStringExtra(EXTRA_CERTIFICATE)
            val verified = intent.getBooleanExtra(EXTRA_VERIFIED_BROWSER, false)
            if (pkg != null && cert != null) {
                NextStep.remember(
                    pkg, cert,
                    if (verified) intent.getStringExtra(EXTRA_WEB_DOMAIN) else null,
                    label, username, password,
                )
            }
        }

        val presentation = RemoteViews(packageName, R.layout.autofill_row).apply {
            setTextViewText(R.id.autofill_row_text, label)
        }

        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder(presentation).apply {
            usernameId?.let { id ->
                setValue(id, AutofillValue.forText(username ?: ""))
            }
            passwordId?.let { id ->
                setValue(id, AutofillValue.forText(password ?: ""))
            }
        }.build()

        // The row that was unlocked is replaced by this dataset, and Android
        // fills it straight away.
        val reply = Intent().putExtra(
            AutofillManager.EXTRA_AUTHENTICATION_RESULT,
            dataset,
        )
        setResult(RESULT_OK, reply)
        finish()
    }

    @Suppress("DEPRECATION")
    private fun intentExtraAutofillId(key: String): AutofillId? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(key, AutofillId::class.java)
        } else {
            intent.getParcelableExtra(key)
        }

    companion object {
        const val CHANNEL = "ringer_vault/autofill"
        const val ENGINE_ID = "ringer_vault/autofill_engine"
        const val ROUTE = "/autofill"

        const val EXTRA_PACKAGE = "package"
        const val EXTRA_TYPED_USERNAME = "typedUsername"
        const val EXTRA_CERTIFICATE = "certificate"
        const val EXTRA_WEB_DOMAIN = "webDomain"
        const val EXTRA_WEB_SCHEME = "webScheme"
        const val EXTRA_KNOWN_BROWSER = "knownBrowser"
        const val EXTRA_FROM_STORE = "fromStore"
        const val EXTRA_VERIFIED_BROWSER = "verifiedBrowser"
        const val EXTRA_COMPATIBILITY_MODE = "compatibilityMode"
        const val EXTRA_USERNAME_ID = "usernameId"
        const val EXTRA_PASSWORD_ID = "passwordId"
        const val EXTRA_APP_LABEL = "appLabel"
        const val EXTRA_SAVE_TOKEN = "saveToken"
        const val EXTRA_MODE = "mode"

        const val MODE_AUTOFILL = "autofill"
        const val MODE_CREDENTIAL_GET = "credentialGet"
        const val MODE_CREDENTIAL_CREATE = "credentialCreate"
    }
}
