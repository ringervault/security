package com.ringer.vault.autofill

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.autofill.FillRequest
import android.service.autofill.InlinePresentation
import android.view.inputmethod.InlineSuggestionsRequest
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.v1.InlineSuggestionUi
import com.ringer.vault.R

/**
 * Suggestions shown as chips in the keyboard's top strip, for keyboards that
 * take them (Gboard does).
 *
 * Without them Android shows a floating row under the box, and Chrome closes
 * that row when the box is tapped, to bring the keyboard up. When a page puts
 * the cursor in the box by itself (Facebook's "choose account" page does),
 * the row then never comes back, because the box never lost the cursor. A
 * chip lives in the keyboard, so tapping the box brings it up instead.
 *
 * With a keyboard that does not take chips, Android sends no chip request
 * and the floating row is used, as before.
 */
class KeyboardChips @RequiresApi(Build.VERSION_CODES.R) private constructor(
    private val context: Context,
    private val request: InlineSuggestionsRequest,
) {
    private var made = 0

    /**
     * The next chip, saying [text], or null when the keyboard has no room
     * left or does not draw this kind of chip.
     */
    @RequiresApi(Build.VERSION_CODES.R)
    fun next(text: String): InlinePresentation? {
        val specs = request.inlinePresentationSpecs
        if (specs.isEmpty() || made >= request.maxSuggestionCount) return null
        // The keyboard gives one look per chip; the last one is for the rest.
        val spec = specs[minOf(made, specs.size - 1)]
        if (!UiVersions.getVersions(spec.style).contains(UiVersions.INLINE_UI_VERSION_1)) return null
        made += 1
        val content = InlineSuggestionUi.newContentBuilder(attribution())
            .setTitle(text)
            .setContentDescription(text)
            .setStartIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
            .build()
        return InlinePresentation(content.slice, spec, false)
    }

    /**
     * What a long press on a chip runs. Android asks for one; it does
     * nothing here, so a long press never takes the user out of the app
     * they are signing in to.
     */
    @SuppressLint("UnspecifiedImmutableFlag")
    @RequiresApi(Build.VERSION_CODES.R)
    private fun attribution(): PendingIntent = PendingIntent.getService(
        context,
        0,
        Intent(),
        PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        /** Chips for [request], or null when the keyboard asked for none. */
        fun of(context: Context, request: FillRequest): KeyboardChips? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
            val inline = request.inlineSuggestionsRequest ?: return null
            return KeyboardChips(context, inline)
        }
    }
}
