package com.ringer.vault.autofill

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.service.autofill.Dataset
import android.service.autofill.FillResponse
import android.service.autofill.SaveInfo
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.ringer.vault.R

/**
 * The "Unlock Ringer Vault" offer for a login form.
 *
 * The service makes it for a fill request. The unlock screen makes it again
 * when it is closed without unlocking: Android drops the offer once its row
 * has been tapped, and only asks again when the box loses and regains the
 * cursor, so the user who closed the screen by mistake was left with
 * nothing to tap. Handed back, the offer shows again at once.
 */
@RequiresApi(Build.VERSION_CODES.O)
internal object UnlockOffer {
    private const val REQUEST_CODE = 1001

    /**
     * The response: the login chosen on the page before, when there is one
     * ([next]), then the unlock row, which opens [unlockIntent].
     *
     * [FillResponse.Builder.setAuthentication] is what lets a locked password
     * manager take part at all: the system shows the row, and the datasets are
     * produced later by the activity behind it.
     */
    fun response(
        context: Context,
        form: ParsedForm,
        unlockIntent: Intent,
        chips: KeyboardChips?,
        next: NextStep.Held?,
    ): FillResponse {
        val sender = PendingIntent.getActivity(
            context,
            REQUEST_CODE,
            unlockIntent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE,
        ).intentSender

        // Authentication is on the one row, not on the whole response. With
        // the whole response locked, Android showed a second list after the
        // unlock screen closed and waited for another tap, although the user
        // had already chosen the entry inside that screen. A locked row is
        // replaced by the dataset the screen returns and filled at once.
        val unlock = context.getString(R.string.autofill_unlock)
        @Suppress("DEPRECATION")
        val unlockRow = Dataset.Builder(row(context, unlock)).apply {
            // No values yet: they only exist once the vault is open.
            listOfNotNull(form.usernameId, form.passwordId).forEach { id -> setValue(id, null) }
            setAuthentication(sender)
        }

        val builder = FillResponse.Builder()
        // The login chosen on the page before, first and ready to fill; the
        // unlock row stays under it for choosing a different one.
        if (next != null) {
            val label = listOfNotNull(next.label, next.username?.takeIf { it.isNotBlank() })
                .joinToString(" · ")
            @Suppress("DEPRECATION")
            val dataset = Dataset.Builder(row(context, label)).apply {
                form.passwordId?.let { setValue(it, AutofillValue.forText(next.password)) }
                form.usernameId?.let { id ->
                    next.username?.let { setValue(id, AutofillValue.forText(it)) }
                }
                chip(chips, label)
            }.build()
            builder.addDataset(dataset)
        }
        // Its chip after the ready login's, so the chips keep the rows' order.
        builder.addDataset(unlockRow.chip(chips, unlock).build())

        // Offer to remember a credential the user has just typed in.
        saveInfoFor(form)?.let(builder::setSaveInfo)

        return builder.build()
    }

    /** One row of the suggestion list, saying [text]. */
    fun row(context: Context, text: String) = RemoteViews(context.packageName, R.layout.autofill_row).apply {
        setTextViewText(R.id.autofill_row_text, text)
    }

    /** The same row as a keyboard chip, for keyboards that take them. */
    fun Dataset.Builder.chip(chips: KeyboardChips?, text: String): Dataset.Builder = apply {
        if (chips != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            @Suppress("DEPRECATION")
            chips.next(text)?.let { setInlinePresentation(it) }
        }
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
    fun whenToOffer(builder: SaveInfo.Builder, form: ParsedForm) {
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
}
