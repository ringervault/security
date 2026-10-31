package com.ringer.vault.autofill

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.autofill.Dataset
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import com.ringer.vault.R

/**
 * "Use the same password" in a confirm-password box: fills it with what the
 * password box above holds at that moment, generated or typed. Android hands
 * this screen the form as it is now, so the value is read, never guessed. It
 * shows nothing and needs no unlock: nothing comes from the vault. With the
 * password box still empty, nothing is filled.
 */
@RequiresApi(Build.VERSION_CODES.O)
class SamePasswordActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        val structure = intent.getParcelableExtra<AssistStructure>(AutofillManager.EXTRA_ASSIST_STRUCTURE)
        @Suppress("DEPRECATION")
        val from = intent.getParcelableExtra<AutofillId>(EXTRA_FROM)
        @Suppress("DEPRECATION")
        val to = intent.getParcelableArrayListExtra<AutofillId>(EXTRA_TO).orEmpty()
        val password = if (structure != null && from != null) StructureParser.valueOf(structure, from) else null

        if (password.isNullOrEmpty() || to.isEmpty()) {
            setResult(RESULT_CANCELED)
        } else {
            val row = RemoteViews(packageName, R.layout.autofill_row).apply {
                setTextViewText(R.id.autofill_row_text, getString(R.string.autofill_same))
            }
            @Suppress("DEPRECATION")
            val dataset = Dataset.Builder(row).apply {
                to.forEach { setValue(it, AutofillValue.forText(password)) }
            }.build()
            setResult(RESULT_OK, Intent().putExtra(AutofillManager.EXTRA_AUTHENTICATION_RESULT, dataset))
        }
        finish()
    }

    companion object {
        const val EXTRA_FROM = "com.ringer.vault.autofill.SAME_FROM"
        const val EXTRA_TO = "com.ringer.vault.autofill.SAME_TO"
    }
}
