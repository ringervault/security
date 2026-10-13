package com.ringer.vault

import com.ringer.vault.autofill.StructureParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a field is called decides which box gets the password, so the names
 * are matched by whole words: "pin" is not in "shipping", "pass" is not in
 * "passenger", "account" is not in "accounting".
 */
class FieldWordsTest {

    private val password = setOf("password", "passwd", "pass", "pin", "passphrase", "secret")
    private val username = setOf("user", "username", "email", "e-mail", "login", "identifier", "user_name", "userid", "user_id", "account")

    @Test
    fun wordsSplitAtSeparatorsAndCamelCase() {
        assertEquals(listOf("login", "password"), StructureParser.words("loginPassword"))
        assertEquals(listOf("et", "user", "name"), StructureParser.words("et_user-name"))
        assertEquals(listOf("txt", "pin", "2"), StructureParser.words("txtPin 2"))
    }

    @Test
    fun aWordInsideAnotherIsNotAMatch() {
        assertFalse(StructureParser.matchesWord("shipping_address", password))
        assertFalse(StructureParser.matchesWord("mappingField", password))
        assertFalse(StructureParser.matchesWord("typing", password))
        assertFalse(StructureParser.matchesWord("passengerName", password))
        assertFalse(StructureParser.matchesWord("accounting_code", username))
    }

    @Test
    fun realFieldNamesStillMatch() {
        assertTrue(StructureParser.matchesWord("loginPassword", password))
        assertTrue(StructureParser.matchesWord("et_pass", password))
        assertTrue(StructureParser.matchesWord("Enter your PIN", password))
        assertTrue(StructureParser.matchesWord("user_name", username))
        assertTrue(StructureParser.matchesWord("User Name", username))
        assertTrue(StructureParser.matchesWord("emailAddress", username))
        assertTrue(StructureParser.matchesWord("e-mail", username))
        assertTrue(StructureParser.matchesWord("accountNumber", username))
    }

    @Test
    fun runTogetherWordsMatchTheirJoinedForm() {
        val newPassword = setOf("newpassword", "confirm password", "passwordagain")
        assertTrue(StructureParser.matchesWord("new_password", newPassword))
        assertTrue(StructureParser.matchesWord("confirmPassword", newPassword))
        assertTrue(StructureParser.matchesWord("password-again", newPassword))
        assertFalse(StructureParser.matchesWord("password", newPassword))
    }
}
