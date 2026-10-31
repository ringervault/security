package com.ringer.vault

import com.ringer.vault.autofill.PasswordMaker
import com.ringer.vault.autofill.StructureParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The password offered on sign-up and change-password forms. */
class SignUpTest {
    @Test
    fun aMadeUpPasswordHasEveryKindAndNoLookAlikes() {
        repeat(200) {
            val password = PasswordMaker.make()
            assertEquals(PasswordMaker.LENGTH, password.length)
            assertTrue(password, password.any { it in 'a'..'z' })
            assertTrue(password, password.any { it in 'A'..'Z' })
            assertTrue(password, password.any { it in '2'..'9' })
            assertTrue(password, password.any { it in PasswordMaker.DEFAULT_SYMBOLS })
            assertTrue(password, password.none { it in "lI1O0" })
        }
    }

    @Test
    fun onlyTheSpecialCharactersAllowedInTheAppAreUsed() {
        repeat(200) {
            val special = PasswordMaker.make("_ .").filter { !it.isLetterOrDigit() }
            assertTrue(special, special.isNotEmpty() && special.all { it in "_." })
        }
        repeat(50) {
            val password = PasswordMaker.make("abc 123")
            assertTrue(password, password.all { it.isLetterOrDigit() })
        }
        assertEquals("!@#\$", PasswordMaker.cleanSymbols("! @ # \$ !"))
    }

    @Test
    fun aConfirmBoxConfirmsThePlainPasswordBoxBeforeIt() {
        val (P, C, N, K) = listOf(
            StructureParser.BoxKind.PLAIN, StructureParser.BoxKind.CURRENT,
            StructureParser.BoxKind.NEW, StructureParser.BoxKind.CONFIRM,
        )
        // "Password", then "Confirm password": the generator goes in the first.
        assertEquals(listOf(0, 1) to null, StructureParser.newPasswordPlan(listOf(P, K), signUpButton = false))
        // Marked new and confirm.
        assertEquals(listOf(0, 1) to null, StructureParser.newPasswordPlan(listOf(N, K), signUpButton = false))
        // Current, new, confirm: the current one is kept for the current password.
        assertEquals(listOf(1, 2) to 0, StructureParser.newPasswordPlan(listOf(C, N, K), signUpButton = false))
        // An unmarked current password, then "Password" and "Confirm password".
        assertEquals(listOf(1, 2) to 0, StructureParser.newPasswordPlan(listOf(P, P, K), signUpButton = false))
        // Two plain boxes on a login form stay a login.
        assertEquals(emptyList<Int>() to 0, StructureParser.newPasswordPlan(listOf(P, P), signUpButton = false))
        // The same beside a sign-up button are a password and its confirmation.
        assertEquals(listOf(0, 1) to null, StructureParser.newPasswordPlan(listOf(P, P), signUpButton = true))
        // One box alone is a login's.
        assertEquals(emptyList<Int>() to 0, StructureParser.newPasswordPlan(listOf(P), signUpButton = true))
    }

    @Test
    fun whichPlainPasswordBoxesAreForANewPassword() {
        assertEquals(emptyList<Int>(), StructureParser.newPasswordBoxes(listOf(false)))
        // A password and its confirmation.
        assertEquals(listOf(0, 1), StructureParser.newPasswordBoxes(listOf(false, false)))
        // Current, new, confirm, with nothing marked: the first is the current one.
        assertEquals(listOf(1, 2), StructureParser.newPasswordBoxes(listOf(false, false, false)))
        // Marked current wherever it is.
        assertEquals(listOf(0, 2), StructureParser.newPasswordBoxes(listOf(false, true, false)))
    }
}
