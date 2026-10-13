package com.ringer.vault

import com.ringer.vault.autofill.BrowserAllowlist
import com.ringer.vault.autofill.NextStep
import com.ringer.vault.autofill.RequestIdentity
import com.ringer.vault.autofill.VaultSession
import com.ringer.vault.credentials.CredentialCaller
import com.ringer.vault.credentials.CredentialHandoff
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The provider's and the autofill service's rules that need no device:
 * which origin is believed, who a chosen login goes back to, and the login
 * kept for the second page of a sign-in (docs/CREDENTIAL_PROVIDER.md).
 */
class CredentialRulesTest {
    private val chromeCert = "f0fd6c5b410f25cb25c3b53346c8972fae30f8ee7411df910480ad6b2d60db83"
    private val appCert = "ab".repeat(32)
    private var now = 1_000_000L

    private fun identity(pkg: String, cert: String, browser: Boolean = false) =
        RequestIdentity(pkg, cert, installedFromStore = true, isVerifiedBrowser = browser)

    private val chrome = identity("com.android.chrome", chromeCert, browser = true)
    private val amazonApp = identity("in.amazon.mShop.android.shopping", appCert)

    private fun inChrome(host: String) = CredentialCaller(chrome, "https", host, knownBrowser = true)
    private val asApp = CredentialCaller(amazonApp, null, null, knownBrowser = false)

    @Before
    fun clocks() {
        NextStep.clock = { now }
        CredentialHandoff.clock = { now }
        NextStep.clear()
        CredentialHandoff.clear()
    }

    @After
    fun tidy() {
        NextStep.clear()
        CredentialHandoff.clear()
    }

    // Which origin is believed.

    @Test
    fun originsAreReadAsSchemeAndHost() {
        assertEquals("https" to "www.amazon.in", CredentialCaller.parseOrigin("https://www.amazon.in"))
        assertEquals("https" to "www.amazon.in", CredentialCaller.parseOrigin("https://www.Amazon.in/"))
        assertEquals("https" to "accounts.example.com", CredentialCaller.parseOrigin("https://accounts.example.com:443"))
        assertEquals("http" to "example.com", CredentialCaller.parseOrigin("http://example.com"))
    }

    @Test
    fun anythingButAWebOriginIsRefused() {
        assertNull(CredentialCaller.parseOrigin("android:apk-key-hash:abc"))
        assertNull(CredentialCaller.parseOrigin("ftp://example.com"))
        assertNull(CredentialCaller.parseOrigin("https://"))
        assertNull(CredentialCaller.parseOrigin("not an origin"))
    }

    @Test
    fun onlyBrowsersWithAKnownCertificateMayNameAnOrigin() {
        val json = BrowserAllowlist.privilegedAppsJson()
        assertTrue(json.contains("\"package_name\":\"com.android.chrome\""))
        assertTrue(json.contains("F0:FD:6C:5B:41:0F:25:CB"))
        // Listed browsers without a known certificate are not privileged.
        assertFalse(json.contains("org.mozilla.firefox"))
        assertFalse(json.contains("com.brave.browser"))
    }

    // A chosen login goes back once, to the same caller only.

    @Test
    fun aChosenLoginGoesBackOnceToTheSameCaller() {
        val token = CredentialHandoff.put(inChrome("www.amazon.in"), "ada@example.com", "pw")
        assertNotNull(CredentialHandoff.take(token, inChrome("www.amazon.in")))
        assertNull("used up", CredentialHandoff.take(token, inChrome("www.amazon.in")))
    }

    @Test
    fun aChosenLoginNeverGoesToAnotherSiteOrApp() {
        val t1 = CredentialHandoff.put(inChrome("www.amazon.in"), "ada", "pw")
        assertNull(CredentialHandoff.take(t1, inChrome("www.amaz0n.in")))
        val t2 = CredentialHandoff.put(inChrome("www.amazon.in"), "ada", "pw")
        assertNull(CredentialHandoff.take(t2, asApp))
        val t3 = CredentialHandoff.put(asApp, "ada", "pw")
        val impostor = CredentialCaller(identity(amazonApp.packageName, "cd".repeat(32)), null, null, false)
        assertNull("same package, other signer", CredentialHandoff.take(t3, impostor))
        assertNull("no caller at all", CredentialHandoff.take(CredentialHandoff.put(asApp, "a", "p"), null))
    }

    @Test
    fun aChosenLoginWaitsTwoMinutesAtMostAndGoesWithALock() {
        val token = CredentialHandoff.put(asApp, "ada", "pw")
        now += CredentialHandoff.LIFETIME_MS + 1
        assertNull(CredentialHandoff.take(token, asApp))
        val again = CredentialHandoff.put(asApp, "ada", "pw")
        CredentialHandoff.clear()
        assertNull(CredentialHandoff.take(again, asApp))
    }

    // The login kept for the next page of a sign-in (NextStep).

    private fun keep(pkg: String, cert: String, host: String?) =
        NextStep.remember(pkg, cert, host, "Amazon", "ada@example.com", "pw")

    @Test
    fun theNextPageOfTheSameSiteGetsIt() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        assertNotNull(NextStep.matching(chrome, "www.amazon.in"))
        assertNotNull("with or without www", NextStep.matching(chrome, "amazon.in"))
    }

    @Test
    fun anotherSitesPasswordBoxNeverGetsIt() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        assertNull(NextStep.matching(chrome, "www.amazon.com"))
        assertNull(NextStep.matching(chrome, "evil-amazon.in"))
        assertNull("a shared ending is not a site", NextStep.matching(chrome, "in"))
        assertNull("nor is a parent beyond www", NextStep.matching(chrome, "amazon.co.in"))
    }

    @Test
    fun siblingsAreNotTheSameSite() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        assertNull(NextStep.matching(chrome, "pay.amazon.in"))
        keep(chrome.packageName, chromeCert, "www.amazon.co.uk")
        assertNull("a public suffix is not a site", NextStep.matching(chrome, "co.uk"))
    }

    @Test
    fun anotherAppNeverGetsIt() {
        keep(amazonApp.packageName, appCert, null)
        assertNotNull(NextStep.matching(amazonApp, null))
        assertNull(NextStep.matching(identity("com.evil.app", appCert), null))
        assertNull("same package, other signer", NextStep.matching(identity(amazonApp.packageName, "cd".repeat(32)), null))
        assertNull("an app's login is not a site's", NextStep.matching(chrome, "www.amazon.in"))
    }

    @Test
    fun itExpiresAfterTwoMinutes() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        now += NextStep.LIFETIME_MS + 1
        assertNull(NextStep.matching(chrome, "www.amazon.in"))
    }

    @Test
    fun aLockClearsIt() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        NextStep.clear()
        assertNull(NextStep.matching(chrome, "www.amazon.in"))
    }

    // What the app's own lock and unlock do to them.

    @Test
    fun openingTheDecoyDropsEverythingKept() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        val token = CredentialHandoff.put(asApp, "ada", "pw")
        VaultSession.unlocked(decoy = true, byPin = true)
        assertNull(NextStep.matching(chrome, "www.amazon.in"))
        assertNull(CredentialHandoff.take(token, asApp))
        assertFalse("and no fingerprint after the decoy", VaultSession.fingerprintAllowed)
    }

    @Test
    fun theRealVaultsUnlockKeepsWhatWasKept() {
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        VaultSession.unlocked(decoy = false, byPin = true)
        assertNotNull(NextStep.matching(chrome, "www.amazon.in"))
    }

    @Test
    fun lockingDropsEverythingKept() {
        // Auto-lock on leaving the app, the timer and a panic shake all lock.
        keep(chrome.packageName, chromeCert, "www.amazon.in")
        val token = CredentialHandoff.put(asApp, "ada", "pw")
        VaultSession.locked()
        assertNull(NextStep.matching(chrome, "www.amazon.in"))
        assertNull(CredentialHandoff.take(token, asApp))
    }
}
