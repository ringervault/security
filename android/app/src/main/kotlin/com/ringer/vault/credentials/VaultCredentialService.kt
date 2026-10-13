package com.ringer.vault.credentials

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.AuthenticationAction
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePasswordCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPasswordOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import com.ringer.vault.R
import com.ringer.vault.autofill.AutofillUnlockActivity

/**
 * Ringer Vault as a Credential Manager provider (Android 14 and later):
 * passwords in the "Use saved password or passkey?" sheet.
 *
 * Like the autofill service, it holds no key and can read nothing. While the
 * vault is locked, which is always when this runs, it offers one unlock
 * action; the screen behind it (AutofillUnlockActivity, the same one as the
 * autofill row) unlocks, applies every rule and warning, and hands one login
 * back. See docs/CREDENTIAL_PROVIDER.md for how this and the autofill
 * service never offer the same login at once.
 *
 * Passwords only: a passkey request is not answered.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class VaultCredentialService : CredentialProviderService() {

    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        val nothing = BeginGetCredentialResponse()
        if (request.beginGetCredentialOptions.none { it is BeginGetPasswordOption }) {
            callback.onResult(nothing)
            return
        }
        val info = request.callingAppInfo
        val caller = info?.let { CredentialCaller.from(this, it) }
        if (caller == null) {
            callback.onResult(nothing)
            return
        }

        val unlock = Intent(this, AutofillUnlockActivity::class.java)
            .putExtra(AutofillUnlockActivity.EXTRA_MODE, AutofillUnlockActivity.MODE_CREDENTIAL_GET)
        val pending = PendingIntent.getActivity(
            this, REQUEST_GET, unlock,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        callback.onResult(
            BeginGetCredentialResponse.Builder()
                .addAuthenticationAction(AuthenticationAction(getString(R.string.autofill_unlock), pending))
                .build(),
        )
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        if (request !is BeginCreatePasswordCredentialRequest) {
            callback.onError(CreateCredentialUnsupportedException("Ringer Vault saves passwords only."))
            return
        }
        val caller = request.callingAppInfo?.let { CredentialCaller.from(this, it) }
        if (caller == null) {
            callback.onError(CreateCredentialUnsupportedException("Cannot save for this app."))
            return
        }
        val save = Intent(this, AutofillUnlockActivity::class.java)
            .putExtra(AutofillUnlockActivity.EXTRA_MODE, AutofillUnlockActivity.MODE_CREDENTIAL_CREATE)
        val pending = PendingIntent.getActivity(
            this, REQUEST_CREATE, save,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        callback.onResult(
            BeginCreateCredentialResponse(
                createEntries = listOf(CreateEntry.Builder(getString(R.string.autofill_service_label), pending).build()),
            ),
        )
    }

    /** Ringer Vault keeps no sign-in state for apps: nothing to clear. */
    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) {
        callback.onResult(null)
    }

    private companion object {
        const val REQUEST_GET = 7101
        const val REQUEST_CREATE = 7102
    }
}
