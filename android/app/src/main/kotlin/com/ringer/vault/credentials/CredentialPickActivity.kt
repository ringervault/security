package com.ringer.vault.credentials

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.annotation.RequiresApi
import androidx.credentials.GetCredentialResponse
import androidx.credentials.PasswordCredential
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.PendingIntentHandler

/**
 * Behind the one entry the sheet shows after Ringer Vault's screen: hands
 * the chosen login over, with no screen of its own. The login comes from
 * [CredentialHandoff] by the token in the intent, once, and only to the
 * caller Android names now, which must be the one that asked.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class CredentialPickActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val caller = request?.callingAppInfo?.let { CredentialCaller.from(this, it) }
        val held = CredentialHandoff.take(intent.getStringExtra(EXTRA_TOKEN), caller)

        val result = Intent()
        if (held == null) {
            PendingIntentHandler.setGetCredentialException(
                result,
                GetCredentialUnknownException("That login is no longer waiting. Unlock Ringer Vault again."),
            )
        } else {
            PendingIntentHandler.setGetCredentialResponse(
                result,
                GetCredentialResponse(PasswordCredential(held.username, held.password)),
            )
        }
        setResult(RESULT_OK, result)
        finish()
    }

    companion object {
        const val EXTRA_TOKEN = "token"
    }
}
