package com.ringer.vault.autofill

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveInfo
import android.service.autofill.SaveRequest
import android.view.autofill.AutofillValue
import androidx.annotation.RequiresApi
import com.ringer.vault.R
import com.ringer.vault.autofill.UnlockOffer.chip

/**
 * Answers the system when the user taps a login field in another app.
 *
 * The vault is locked whenever this runs, and this service has no way to open
 * it: the key only exists after the user has authenticated. So the response is
 * never credentials. It is a single row that says "Unlock Ringer Vault", with
 * an authentication intent behind it. Only after the user has unlocked, in an
 * activity of ours, are datasets handed back to the system.
 *
 * That shape is not a workaround, it is the design. A service that could fill
 * silently would be a service that holds the vault key while the app is
 * closed.
 */
@RequiresApi(Build.VERSION_CODES.O)
class VaultAutofillService : AutofillService() {

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val context = request.fillContexts.lastOrNull()
        if (context == null) {
            callback.onSuccess(null)
            return
        }

        val structure = context.structure
        val form = StructureParser.parse(structure)
        if (!form.isUsable) {
            callback.onSuccess(null)
            return
        }

        val callerPackage = structure.activityComponent?.packageName
        if (callerPackage == null || callerPackage == packageName) {
            // Never offer to fill our own screens.
            callback.onSuccess(null)
            return
        }

        val identity = RequestIdentity.of(this, callerPackage)
        if (identity == null) {
            callback.onSuccess(null)
            return
        }

        // Compatibility mode requests are reconstructed from accessibility
        // events rather than a real view structure, so they are easier to
        // spoof and are marked for the unlock screen to treat carefully.
        val compatibilityMode = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            (request.flags and FillRequest.FLAG_COMPATIBILITY_MODE_REQUEST) != 0

        // A sign-up or change-password form is asking the user to invent a
        // password, not to produce one they already have. Offering a stored
        // credential here invites filling the old password into the "new
        // password" box, which is how people lock themselves out. What is
        // useful here is the opposite: offering to save the new password.
        val chips = KeyboardChips.of(this, request)
        if (form.isSignUp) {
            callback.onSuccess(buildSaveOnlyResponse(form, chips))
            return
        }

        // The username already typed by hand: on this screen, or on the
        // step before when the system still has it in this session. It only
        // decides which logins are listed first; it never fills anything.
        val typedUsername = form.usernameValue?.trim()?.takeIf { it.isNotEmpty() }
            ?: request.fillContexts.dropLast(1).asReversed().firstNotNullOfOrNull {
                StructureParser.parse(it.structure).usernameValue?.trim()?.takeIf { v -> v.isNotEmpty() }
            }

        // Step two of a sign-in whose first page was filled a moment ago:
        // that login, ready to fill (NextStep).
        val next = if (form.passwordId != null && !compatibilityMode) {
            NextStep.matching(identity, if (identity.isVerifiedBrowser) form.webDomain else null)
        } else {
            null
        }
        callback.onSuccess(buildUnlockResponse(form, identity, compatibilityMode, typedUsername, next, chips))
    }

    /** Everything the screen needs to know about who is asking. */
    private fun identityIntent(
        identity: RequestIdentity,
        webDomain: String?,
        webScheme: String?,
        compatibilityMode: Boolean,
    ) = Intent(this, AutofillUnlockActivity::class.java).apply {
        putExtra(AutofillUnlockActivity.EXTRA_PACKAGE, identity.packageName)
        putExtra(AutofillUnlockActivity.EXTRA_CERTIFICATE, identity.certificateSha256)
        putExtra(AutofillUnlockActivity.EXTRA_FROM_STORE, identity.installedFromStore)
        putExtra(AutofillUnlockActivity.EXTRA_VERIFIED_BROWSER, identity.isVerifiedBrowser)
        putExtra(AutofillUnlockActivity.EXTRA_COMPATIBILITY_MODE, compatibilityMode)
        putExtra(AutofillUnlockActivity.EXTRA_WEB_DOMAIN, webDomain)
        putExtra(AutofillUnlockActivity.EXTRA_WEB_SCHEME, webScheme)
        putExtra(
            AutofillUnlockActivity.EXTRA_KNOWN_BROWSER,
            BrowserAllowlist.isBrowser(this@VaultAutofillService, identity.packageName),
        )
        putExtra(AutofillUnlockActivity.EXTRA_APP_LABEL, RequestIdentity.labelOf(this@VaultAutofillService, identity.packageName))
    }

    /** A sign-up form: nothing to fill, but the new password is worth keeping. */
    private fun buildSaveOnlyResponse(form: ParsedForm, chips: KeyboardChips?): FillResponse? {
        val newPassword = form.newPasswordId ?: return null
        val info = SaveInfo.Builder(
            SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD,
            arrayOf(newPassword),
        ).apply {
            form.usernameId?.let { setOptionalIds(arrayOf(it)) }
            UnlockOffer.whenToOffer(this, form)
        }.build()

        // The password box offers a strong password, made here and now, so
        // nothing from the vault is involved and no unlock is needed. The
        // confirm box offers whatever the password box holds when it is
        // tapped, generated or typed (SamePasswordActivity reads it then).
        // Each is shown only in its own box. The password is offered for
        // saving when the form is sent.
        val boxes = form.newPasswordIds.ifEmpty { listOf(newPassword) }
        val builder = FillResponse.Builder()

        val password = PasswordMaker.make(PasswordMaker.allowedSymbols(this))
        @Suppress("DEPRECATION")
        val generated = Dataset.Builder(row(R.string.autofill_generate))
            .setValue(boxes.first(), AutofillValue.forText(password))
            .chip(chips, getString(R.string.autofill_generate))
            .build()
        builder.addDataset(generated)

        val confirms = boxes.drop(1)
        if (confirms.isNotEmpty()) {
            val intent = Intent(this, SamePasswordActivity::class.java)
                .putExtra(SamePasswordActivity.EXTRA_FROM, boxes.first())
                .putParcelableArrayListExtra(SamePasswordActivity.EXTRA_TO, ArrayList(confirms))
            val sender = PendingIntent.getActivity(
                this,
                SAME_PASSWORD_REQUEST,
                intent,
                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
            ).intentSender
            @Suppress("DEPRECATION")
            val same = Dataset.Builder(row(R.string.autofill_same)).apply {
                confirms.forEach { setValue(it, null) }
                setAuthentication(sender)
                chip(chips, getString(R.string.autofill_same))
            }.build()
            builder.addDataset(same)
        }

        return builder.setSaveInfo(info).build()
    }

    /** One row of the suggestion list, saying [text]. */
    private fun row(text: Int) = UnlockOffer.row(this, getString(text))

    /** The unlock row for a login form, and the login ready from the page before. */
    private fun buildUnlockResponse(
        form: ParsedForm,
        identity: RequestIdentity,
        compatibilityMode: Boolean,
        typedUsername: String?,
        next: NextStep.Held?,
        chips: KeyboardChips?,
    ): FillResponse {
        val intent = identityIntent(identity, form.webDomain, form.webScheme, compatibilityMode).apply {
            putExtra(AutofillUnlockActivity.EXTRA_USERNAME_ID, form.usernameId)
            putExtra(AutofillUnlockActivity.EXTRA_PASSWORD_ID, form.passwordId)
            putExtra(AutofillUnlockActivity.EXTRA_TYPED_USERNAME, typedUsername)
        }
        return UnlockOffer.response(this, form, intent, chips, next)
    }

    /**
     * The user typed a login and tapped Save on Android's prompt.
     *
     * The vault is locked here, as it is for a fill, so nothing is written
     * yet. The login is held in memory and our screen opens to unlock and
     * save it, or update the entry it belongs to.
     */
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val contexts = request.fillContexts
        val structure = contexts.lastOrNull()?.structure
        val callerPackage = structure?.activityComponent?.packageName
        if (structure == null || callerPackage == null || callerPackage == packageName) {
            callback.onFailure(getString(R.string.autofill_save_nothing))
            return
        }

        val identity = RequestIdentity.of(this, callerPackage)
        if (identity == null) {
            callback.onFailure(getString(R.string.autofill_save_nothing))
            return
        }

        // A two-step sign-in leaves the username on an earlier screen, so
        // every screen in the session is looked at, latest first.
        var username: String? = null
        var password: String? = null
        var webDomain: String? = null
        var webScheme: String? = null
        for (context in contexts.reversed()) {
            val form = StructureParser.parse(context.structure)
            if (password == null) password = form.newPasswordValue ?: form.passwordValue
            if (username == null) username = form.usernameValue
            if (webDomain == null && form.webDomain != null) {
                webDomain = form.webDomain
                webScheme = form.webScheme
            }
        }

        if (password.isNullOrEmpty()) {
            callback.onFailure(getString(R.string.autofill_save_nothing))
            return
        }

        val token = PendingSaves.put(PendingSave(username, password))
        val intent = identityIntent(identity, webDomain, webScheme, compatibilityMode = false)
            .putExtra(AutofillUnlockActivity.EXTRA_SAVE_TOKEN, token)

        // Opened directly rather than handed back to Android to open. Android
        // asks the app the login came from to open it, and that app is often
        // closing at this moment (which is what triggered the save), so the
        // screen never appeared. An app with an autofill service in use is
        // allowed to open its own screen from the background.
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        callback.onSuccess()
    }

    private companion object {
        const val SAME_PASSWORD_REQUEST = 1002
    }
}
