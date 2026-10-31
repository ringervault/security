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
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.ringer.vault.R

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

        val fillIds = listOfNotNull(form.usernameId, form.passwordId)
        // Step two of a sign-in whose first page was filled a moment ago:
        // that login, ready to fill (NextStep).
        val next = if (form.passwordId != null && !compatibilityMode) {
            NextStep.matching(identity, if (identity.isVerifiedBrowser) form.webDomain else null)
        } else {
            null
        }
        callback.onSuccess(buildUnlockResponse(form, fillIds, identity, compatibilityMode, typedUsername, next, chips))
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
            whenToOffer(this, form)
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
    private fun row(text: Int) = RemoteViews(packageName, R.layout.autofill_row).apply {
        setTextViewText(R.id.autofill_row_text, getString(text))
    }

    /** The same row as a keyboard chip, for keyboards that take them. */
    private fun Dataset.Builder.chip(chips: KeyboardChips?, text: String): Dataset.Builder = apply {
        if (chips != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            @Suppress("DEPRECATION")
            chips.next(text)?.let { setInlinePresentation(it) }
        }
    }

    /**
     * A response whose only content is an authentication prompt.
     *
     * [FillResponse.Builder.setAuthentication] is what lets a locked password
     * manager take part at all: the system shows the row, and the datasets are
     * produced later by the activity behind it.
     */
    private fun buildUnlockResponse(
        form: ParsedForm,
        fillIds: List<AutofillId>,
        identity: RequestIdentity,
        compatibilityMode: Boolean,
        typedUsername: String? = null,
        next: NextStep.Held? = null,
        chips: KeyboardChips? = null,
    ): FillResponse {
        val presentation = RemoteViews(packageName, R.layout.autofill_row).apply {
            setTextViewText(R.id.autofill_row_text, getString(R.string.autofill_unlock))
        }

        val intent = identityIntent(identity, form.webDomain, form.webScheme, compatibilityMode).apply {
            putExtra(AutofillUnlockActivity.EXTRA_USERNAME_ID, form.usernameId)
            putExtra(AutofillUnlockActivity.EXTRA_PASSWORD_ID, form.passwordId)
            putExtra(AutofillUnlockActivity.EXTRA_TYPED_USERNAME, typedUsername)
        }

        val sender = PendingIntent.getActivity(
            this,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender

        // Authentication is on the one row, not on the whole response. With
        // the whole response locked, Android showed a second list after the
        // unlock screen closed and waited for another tap, although the user
        // had already chosen the entry inside that screen. A locked row is
        // replaced by the dataset the screen returns and filled at once.
        @Suppress("DEPRECATION")
        val unlockRow = Dataset.Builder(presentation).apply {
            // No values yet: they only exist once the vault is open.
            fillIds.forEach { id -> setValue(id, null) }
            setAuthentication(sender)
        }

        val builder = FillResponse.Builder()
        // The login chosen on the page before, first and ready to fill; the
        // unlock row stays under it for choosing a different one.
        if (next != null) {
            val label = listOfNotNull(next.label, next.username?.takeIf { it.isNotBlank() })
                .joinToString(" \u00b7 ")
            val ready = RemoteViews(packageName, R.layout.autofill_row).apply {
                setTextViewText(R.id.autofill_row_text, label)
            }
            @Suppress("DEPRECATION")
            val dataset = Dataset.Builder(ready).apply {
                form.passwordId?.let { setValue(it, AutofillValue.forText(next.password)) }
                form.usernameId?.let { id ->
                    next.username?.let { setValue(id, AutofillValue.forText(it)) }
                }
                chip(chips, label)
            }.build()
            builder.addDataset(dataset)
        }
        // Its chip after the ready login's, so the chips keep the rows' order.
        builder.addDataset(unlockRow.chip(chips, getString(R.string.autofill_unlock)).build())

        // Offer to remember a credential the user has just typed in.
        saveInfoFor(form)?.let(builder::setSaveInfo)

        return builder.build()
    }

    /**
     * When to offer saving, and what.
     *
     * The password is required: a form saved without one is not a login.
     * "Save when the fields go away" catches the many apps and pages that
     * sign in by swapping the screen rather than finishing the activity.
     *
     * A page with only a username (step one of a two-step sign-in, as on
     * Amazon or Google) asks Android to hold on to it and offer saving after
     * the password page, so the two are saved together. Before Android 10
     * there is no way to do that, so nothing is offered for that page.
     */
    private fun saveInfoFor(form: ParsedForm): SaveInfo? {
        val password = form.passwordId
        if (password != null) {
            return SaveInfo.Builder(
                SaveInfo.SAVE_DATA_TYPE_USERNAME or SaveInfo.SAVE_DATA_TYPE_PASSWORD,
                arrayOf(password),
            ).apply {
                form.usernameId?.let { setOptionalIds(arrayOf(it)) }
                whenToOffer(this, form)
            }.build()
        }

        val username = form.usernameId ?: return null
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_USERNAME, arrayOf(username))
            .setFlags(SaveInfo.FLAG_DELAY_SAVE)
            .build()
    }

    /**
     * Saving is offered when the form is sent, and only then.
     *
     * In an app, that is the tap on its login or sign-up button. Without
     * this, the offer also came whenever the fields left the screen: moving
     * to another tab, a dialog covering the form, or going back, which is
     * offering to save a password nobody had finished typing.
     *
     * A web page is sent by the browser, which tells Android itself when a
     * form is submitted, and moves on to the next page afterwards. An app
     * whose button could not be recognised keeps the old rule, so it is
     * still offered at some point rather than never.
     */
    private fun whenToOffer(builder: SaveInfo.Builder, form: ParsedForm) {
        val submit = form.submitId
        when {
            form.webDomain != null ->
                builder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
            // Closing the app (Back, say) no longer counts as sending it.
            submit != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> {
                builder.setTriggerId(submit)
                builder.setFlags(SaveInfo.FLAG_DONT_SAVE_ON_FINISH)
            }
            else ->
                builder.setFlags(SaveInfo.FLAG_SAVE_ON_ALL_VIEWS_INVISIBLE)
        }
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
        const val REQUEST_CODE = 1001
        const val SAME_PASSWORD_REQUEST = 1002
    }
}
