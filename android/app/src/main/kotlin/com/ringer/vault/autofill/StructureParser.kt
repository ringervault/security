package com.ringer.vault.autofill

import android.app.assist.AssistStructure
import android.os.Build
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId
import androidx.annotation.RequiresApi

/** A login form found on the screen that is asking for a credential. */
data class ParsedForm(
    val usernameId: AutofillId?,
    val passwordId: AutofillId?,
    val webDomain: String?,
    /** "https" or "http" when the browser reports it (Android 9 and later). */
    val webScheme: String? = null,
    /**
     * The form is asking the user to choose a new password, so it is a
     * sign-up or a password change rather than a login.
     */
    val isSignUp: Boolean = false,
    /** The first "choose a new password" box on a sign-up or change form. */
    val newPasswordId: AutofillId? = null,
    /**
     * Every "choose a new password" box on the form, the confirm box too, in
     * screen order: a generated password goes into all of them.
     */
    val newPasswordIds: List<AutofillId> = emptyList(),
    /**
     * What is typed in the fields. Empty when a fill is requested; filled in
     * when Android hands the form back to be saved.
     */
    val usernameValue: String? = null,
    val passwordValue: String? = null,
    val newPasswordValue: String? = null,
    /**
     * The button that sends the form: "Log in" on a login form, "Sign up" or
     * "Create account" on a sign-up form. Saving is offered when it is
     * tapped, not whenever the fields happen to leave the screen.
     */
    val submitId: AutofillId? = null,
) {
    val isUsable: Boolean get() = passwordId != null || usernameId != null
}

/** A web page's domain and scheme, as the browser reported them. */
private data class Page(val domain: String, val scheme: String?)

/**
 * Finds the username and password fields in another app's view tree.
 *
 * Two rules here are security rules rather than parsing rules.
 *
 * Invisible fields are ignored. A form with a visible username box and a
 * hidden password box beside it is a standard way to harvest a fill the user
 * believed was going somewhere else.
 *
 * The web domain is read but never trusted here. Whether it is worth
 * believing is decided by [RequestIdentity], which checks whether the app
 * reporting it is actually a browser.
 */
@RequiresApi(Build.VERSION_CODES.O)
object StructureParser {

    private val USERNAME_HINTS = setOf(
        View.AUTOFILL_HINT_USERNAME,
        View.AUTOFILL_HINT_EMAIL_ADDRESS,
        "user", "username", "email", "e-mail", "login", "identifier",
        "user_name", "userid", "user_id", "account",
    )

    private val PASSWORD_HINTS = setOf(
        View.AUTOFILL_HINT_PASSWORD,
        "password", "passwd", "pass", "pin", "passphrase", "secret",
    )

    /**
     * Fields a stored password must never be typed into.
     *
     * A one-time code box and a search box both look like ordinary text
     * fields, and both are places where a password put in by mistake ends up
     * somewhere it cannot be taken back from: sent to a server as a search
     * query, or shown in plain text on screen.
     */
    private val NEVER_FILL = setOf(
        "search", "query", "url_bar", "urlbar", "address_bar",
        "otp", "one-time", "onetime", "one_time", "2fa", "twofactor",
        "two-factor", "verification", "verificationcode", "authcode",
        "captcha", "cvv", "cvc", "cardnumber", "card_number", "creditcard",
        "credit_card", "expiry", "expiration",
    )

    /** Tokens meaning "pick a new password", not "enter your password". */
    private val NEW_PASSWORD_HINTS = setOf(
        "newpassword", "new-password", "new_password", "new password",
        "confirmpassword", "confirm-password", "confirm_password",
        "confirm password", "repeatpassword", "repeat password",
        "retypepassword", "retype password", "passwordagain",
        "password_again", "createpassword", "create password",
    )

    /** Words on a button that sends a login form. */
    private val LOGIN_BUTTON_WORDS = listOf(
        "log in", "login", "log on", "logon", "sign in", "signin", "sign-in",
        "sign_in", "submit", "continue", "next", "proceed", "unlock", "enter",
    )

    /** The new-password tokens that mean "the same again": a confirmation box. */
    private val CONFIRM_HINTS = setOf(
        "confirmpassword", "confirm-password", "confirm_password", "confirm password",
        "repeatpassword", "repeat password", "retypepassword", "retype password",
        "passwordagain", "password_again",
    )

    /** Tokens meaning "your current password", on a change-password form. */
    private val CURRENT_PASSWORD_HINTS = setOf(
        "currentpassword", "current-password", "current_password", "current password",
        "oldpassword", "old-password", "old_password", "old password",
    )

    /**
     * Button words that only a sign-up or change-password form uses. Two
     * plain password boxes count as such a form only beside one of these: a
     * login with a password and a PIN box must stay a login.
     */
    private val SIGN_UP_ONLY_WORDS = listOf(
        "sign up", "signup", "sign-up", "sign_up", "register", "create", "join",
        "reset", "change", "update", "set password", "save",
    )

    /** Words on a button that sends a sign-up or change-password form. */
    private val SIGN_UP_BUTTON_WORDS = listOf(
        "sign up", "signup", "sign-up", "sign_up", "register", "create",
        "join", "save", "change", "update", "reset", "submit", "continue",
        "next", "done", "finish",
    )

    /**
     * Buttons that are never the one sending this form: links to the other
     * form, password recovery, and signing in with another provider.
     */
    private val NOT_SUBMIT_WORDS = listOf(
        "forgot", "trouble", "help", "with google", "with apple",
        "with facebook", "with microsoft", "with phone", "with email",
        "cancel", "back", "show", "hide", "remember",
    )

    /** Hints the system itself refuses to autofill into. */
    private val DENIED_SYSTEM_HINTS = setOf(
        View.AUTOFILL_HINT_CREDIT_CARD_NUMBER,
        View.AUTOFILL_HINT_CREDIT_CARD_SECURITY_CODE,
        View.AUTOFILL_HINT_CREDIT_CARD_EXPIRATION_DATE,
        View.AUTOFILL_HINT_POSTAL_CODE,
    )

    fun parse(structure: AssistStructure): ParsedForm {
        var usernameId: AutofillId? = null
        var passwordId: AutofillId? = null
        var webDomain: String? = null
        var webScheme: String? = null
        var sawNewPassword = false
        var newPasswordId: AutofillId? = null
        val newPasswordIds = mutableListOf<AutofillId>()
        // Every password box, in screen order: what kind it says it is, and
        // what is in it. Which are for a new password is decided once all
        // are seen (newPasswordPlan).
        data class Box(val id: AutofillId, val kind: BoxKind, val value: String?, val page: Page?)
        val boxes = mutableListOf<Box>()
        var usernameValue: String? = null
        var passwordValue: String? = null
        var newPasswordValue: String? = null

        // Every visible button, in screen order, with what it says and
        // whether it came after the password box.
        data class Button(val id: AutofillId, val label: String, val afterPassword: Boolean)
        val buttons = mutableListOf<Button>()

        // The page each chosen field is on: the nearest web domain above it.
        // A page can frame another site, so the domain that counts is the
        // one the password box itself is in, not the first in the tree.
        var firstDomain: Page? = null
        var usernamePage: Page? = null
        var passwordPage: Page? = null
        var newPasswordPage: Page? = null

        fun visit(node: AssistStructure.ViewNode, inherited: Page?, parentHidden: Boolean) {
            val page = node.webDomain?.takeIf { it.isNotBlank() }?.let {
                // The scheme is what tells a secure page from one anyone on
                // the network could have rewritten.
                Page(it, if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) node.webScheme?.lowercase() else null)
            } ?: inherited
            if (firstDomain == null && page != null) firstDomain = page
            // A field inside a hidden or see-through parent is hidden too.
            val hidden = parentHidden || node.visibility != View.VISIBLE || node.alpha <= 0f

            if (!hidden && isFillable(node) && !isNeverFill(node)) {
                when {
                    // Checked before isPassword, because a "confirm password"
                    // box looks exactly like a password box.
                    isNewPassword(node) -> node.autofillId?.let {
                        val kind = if (hintsName(node, CONFIRM_HINTS)) BoxKind.CONFIRM else BoxKind.NEW
                        boxes += Box(it, kind, textOf(node), page)
                    }
                    isPassword(node) -> node.autofillId?.let {
                        val kind = if (isCurrentPassword(node)) BoxKind.CURRENT else BoxKind.PLAIN
                        boxes += Box(it, kind, textOf(node), page)
                    }
                    isUsername(node) -> if (usernameId == null) {
                        usernameId = node.autofillId
                        usernameValue = textOf(node)
                        usernamePage = page
                    }
                }
            }

            if (isButton(node)) {
                val id = node.autofillId
                val label = buttonLabel(node)
                if (id != null && label.isNotBlank()) {
                    buttons += Button(id, label, boxes.isNotEmpty())
                }
            }

            for (i in 0 until node.childCount) visit(node.getChildAt(i), page, hidden)
        }

        for (i in 0 until structure.windowNodeCount) {
            visit(structure.getWindowNodeAt(i).rootViewNode, null, false)
        }

        // Which boxes take a new password, and which the current one.
        val signUpButton = buttons.any { b -> SIGN_UP_ONLY_WORDS.any { b.label.contains(it) } }
        val (fresh, current) = newPasswordPlan(boxes.map { it.kind }, signUpButton)
        sawNewPassword = fresh.isNotEmpty()
        newPasswordIds += fresh.map { boxes[it].id }
        fresh.firstOrNull()?.let { first ->
            newPasswordId = boxes[first].id
            newPasswordValue = boxes[first].value
            newPasswordPage = boxes[first].page
        }
        current?.let {
            passwordId = boxes[it].id
            passwordValue = boxes[it].value
            passwordPage = boxes[it].page
        }

        // The page that counts: the password box's, else the new password
        // box's, else the username box's, else the first in the tree. A
        // username box on one site and a password box on another is a form
        // stitched across frames, and nothing in it is filled or saved.
        val formPage = passwordPage ?: newPasswordPage ?: usernamePage ?: firstDomain
        val pages = listOfNotNull(usernamePage, passwordPage, newPasswordPage).map { it.domain.lowercase() }.toSet()
        if (pages.size > 1) {
            usernameId = null
            passwordId = null
            newPasswordId = null
            newPasswordIds.clear()
            usernameValue = null
            passwordValue = null
            newPasswordValue = null
        }
        webDomain = formPage?.domain
        webScheme = formPage?.scheme

        // The first fitting button after the password box is the one that
        // sends it; failing that, the first fitting button anywhere (a
        // username-only page has no password box to come after).
        val words = if (sawNewPassword) SIGN_UP_BUTTON_WORDS else LOGIN_BUTTON_WORDS
        fun fits(button: Button) =
            words.any { button.label.contains(it) } &&
                NOT_SUBMIT_WORDS.none { button.label.contains(it) } &&
                (sawNewPassword || listOf("sign up", "signup", "register", "create")
                    .none { button.label.contains(it) })
        val submit = buttons.firstOrNull { it.afterPassword && fits(it) }
            ?: buttons.firstOrNull(::fits)

        return ParsedForm(
            usernameId = usernameId,
            passwordId = passwordId,
            webDomain = webDomain,
            webScheme = webScheme,
            isSignUp = sawNewPassword,
            newPasswordId = newPasswordId,
            newPasswordIds = newPasswordIds.toList(),
            usernameValue = usernameValue,
            passwordValue = passwordValue,
            newPasswordValue = newPasswordValue,
            submitId = submit?.id,
        )
    }

    /** A visible, tappable button, in a native app or a web page. */
    private fun isButton(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillId == null) return false
        if (node.visibility != View.VISIBLE) return false
        if (node.width <= 0 || node.height <= 0) return false

        val html = node.htmlInfo
        if (html != null) {
            val tag = html.tag.lowercase()
            if (tag == "button") return true
            if (tag == "input") {
                val type = htmlAttribute(node, "type")?.lowercase()
                return type == "submit" || type == "button" || type == "image"
            }
            return false
        }

        val className = node.className ?: return false
        return className.endsWith("Button") && !className.endsWith("RadioButton") &&
            !className.endsWith("ToggleButton") && !className.endsWith("CompoundButton")
    }

    /** What a button says, from its text, description, id or HTML. */
    private fun buttonLabel(node: AssistStructure.ViewNode): String = listOfNotNull(
        node.text?.toString(),
        // Android withholds text an app set in code, but names the string
        // resource it came from, such as "action_sign_in".
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            node.textIdEntry?.replace('_', ' ')
        } else {
            null
        },
        node.contentDescription?.toString(),
        node.idEntry?.replace('_', ' '),
        node.htmlInfo?.attributes?.firstOrNull { it.first.equals("value", true) }?.second,
        node.htmlInfo?.attributes?.firstOrNull { it.first.equals("aria-label", true) }?.second,
        node.htmlInfo?.attributes?.firstOrNull { it.first.equals("id", true) }?.second,
    ).joinToString(" ").lowercase()

    /** The text in a field, or null when it is empty. */
    /** What is in the field [id] of [structure] now, or null. */
    fun valueOf(structure: AssistStructure, id: AutofillId): String? {
        fun find(node: AssistStructure.ViewNode): AssistStructure.ViewNode? {
            if (node.autofillId == id) return node
            for (i in 0 until node.childCount) find(node.getChildAt(i))?.let { return it }
            return null
        }
        for (i in 0 until structure.windowNodeCount) {
            find(structure.getWindowNodeAt(i).rootViewNode)?.let { return textOf(it) }
        }
        return null
    }

    private fun textOf(node: AssistStructure.ViewNode): String? =
        node.autofillValue
            ?.takeIf { it.isText }
            ?.textValue
            ?.toString()
            ?.takeIf { it.isNotEmpty() }

    /**
     * A field has to be something the user can actually see and type into.
     * Zero-sized and off-screen nodes are where harvesting hides.
     */
    private fun isFillable(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillId == null) return false
        if (node.visibility != View.VISIBLE) return false
        if (node.alpha <= 0f) return false
        // A box a person can see and tap is far bigger than this; a 1-pixel
        // one is there to collect what it is given.
        if (node.width < MIN_FIELD_PX || node.height < MIN_FIELD_PX) return false
        return node.autofillType == View.AUTOFILL_TYPE_TEXT
    }

    private const val MIN_FIELD_PX = 8

    /**
     * Fields this service refuses to touch at all, whatever else they look
     * like.
     */
    private fun isNeverFill(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillHints?.any { it in DENIED_SYSTEM_HINTS } == true) return true
        return hintsContain(node, NEVER_FILL)
    }

    private fun isNewPassword(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillHints?.any { hint ->
                hint.lowercase().replace(" ", "") in
                    NEW_PASSWORD_HINTS.map { it.replace(" ", "") }
            } == true
        ) {
            return true
        }
        if (htmlAttribute(node, "autocomplete")?.lowercase() == "new-password") {
            return true
        }
        return hintsName(node, NEW_PASSWORD_HINTS)
    }

    /** What a password box says it is for. */
    enum class BoxKind { CURRENT, PLAIN, NEW, CONFIRM }

    /**
     * Which of a form's password boxes take a new password, in screen order
     * (the password first, then its confirmations), and which one takes the
     * current password, if any.
     *
     * Boxes marked as new count, and a confirmation box confirms the plain box
     * just before it when no box before it is marked new: "Password" then
     * "Confirm password". With none marked, plain boxes count only beside a
     * button that only a sign-up or change form has (newPasswordBoxes). A
     * plain box left over is the current password.
     */
    fun newPasswordPlan(kinds: List<BoxKind>, signUpButton: Boolean): Pair<List<Int>, Int?> {
        val marked = kinds.indices.filter { kinds[it] == BoxKind.NEW || kinds[it] == BoxKind.CONFIRM }
        val fresh = if (marked.isNotEmpty()) {
            val first = marked.first()
            val confirmed = if (kinds[first] == BoxKind.CONFIRM) {
                (first - 1 downTo 0).firstOrNull { kinds[it] == BoxKind.PLAIN }
            } else {
                null
            }
            listOfNotNull(confirmed) + marked
        } else if (signUpButton) {
            val plain = kinds.indices.filter { kinds[it] == BoxKind.PLAIN || kinds[it] == BoxKind.CURRENT }
            newPasswordBoxes(plain.map { kinds[it] == BoxKind.CURRENT }).map { plain[it] }
        } else {
            emptyList()
        }
        val current = kinds.indices.firstOrNull {
            it !in fresh && (kinds[it] == BoxKind.CURRENT || kinds[it] == BoxKind.PLAIN)
        }
        return fresh to current
    }

    /**
     * Which of a form's plain password boxes are for a new password, given
     * whether each says it wants the current one. None for a single box. With
     * one marked current, all the others. Unmarked: two are a password and its
     * confirmation; with three or more, the first is taken for the current
     * password, as change-password forms put it first.
     */
    fun newPasswordBoxes(current: List<Boolean>): List<Int> {
        if (current.size < 2) return emptyList()
        if (current.any { it }) return current.indices.filter { !current[it] }
        return if (current.size == 2) listOf(0, 1) else (1 until current.size).toList()
    }

    private fun isCurrentPassword(node: AssistStructure.ViewNode): Boolean {
        if (htmlAttribute(node, "autocomplete")?.lowercase() == "current-password") return true
        return hintsName(node, CURRENT_PASSWORD_HINTS)
    }

    private fun isPassword(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillHints?.any { it.lowercase() in PASSWORD_HINTS } == true) {
            return true
        }

        // A field inside a web page, where inputType is usually meaningless.
        // This is what makes the feature work in a browser at all.
        if (htmlAttribute(node, "type")?.lowercase() == "password") return true
        if (htmlAttribute(node, "autocomplete")?.lowercase() == "current-password") {
            return true
        }

        // A variation is a value inside the variation bits, not a flag of
        // its own. Testing the bits one at a time made an email box (0x20)
        // look like a web password box (0xe0), so the email step of a
        // two-step sign-in was taken for the whole login: a password could
        // be filled into it, and saving was offered there.
        val type = node.inputType
        val variation = type and InputType.TYPE_MASK_VARIATION
        val isTextPassword = when (type and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation in setOf(
                InputType.TYPE_TEXT_VARIATION_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            )
            InputType.TYPE_CLASS_NUMBER ->
                variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
        if (isTextPassword) return true

        return hintsName(node, PASSWORD_HINTS)
    }

    private fun isUsername(node: AssistStructure.ViewNode): Boolean {
        if (node.autofillHints?.any { it.lowercase() in USERNAME_HINTS } == true) {
            return true
        }

        val autocomplete = htmlAttribute(node, "autocomplete")?.lowercase()
        if (autocomplete == "username" || autocomplete == "email") return true
        if (htmlAttribute(node, "type")?.lowercase() == "email") return true

        // An app's email box, declared by its keyboard type.
        val type = node.inputType
        if ((type and InputType.TYPE_MASK_CLASS) == InputType.TYPE_CLASS_TEXT &&
            (type and InputType.TYPE_MASK_VARIATION) in setOf(
                InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS,
            )
        ) {
            return true
        }

        return hintsName(node, USERNAME_HINTS)
    }

    private fun htmlAttribute(node: AssistStructure.ViewNode, name: String): String? =
        node.htmlInfo
            ?.takeIf { it.tag.equals("input", ignoreCase = true) }
            ?.attributes
            ?.firstOrNull { it.first.equals(name, ignoreCase = true) }
            ?.second

    /**
     * Falls back to the strings an app attaches to its own fields. Weaker
     * than a declared hint, which is why it is only ever used to decide which
     * box to fill, never whether the app deserves the credential.
     */
    private fun hintsContain(node: AssistStructure.ViewNode, needles: Set<String>): Boolean {
        val haystack = hintText(node)
        if (haystack.isBlank()) return false
        return needles.any { haystack.lowercase().contains(it) }
    }

    /**
     * [hintsContain] by whole words, for deciding what a field is: "pin"
     * must not be found in "shipping", "pass" in "passenger" or "account"
     * in "accounting". Only the never-fill list keeps the looser match,
     * where finding too much is the safe side.
     */
    private fun hintsName(node: AssistStructure.ViewNode, needles: Set<String>): Boolean {
        val haystack = hintText(node)
        if (haystack.isBlank()) return false
        return matchesWord(haystack, needles)
    }

    private fun hintText(node: AssistStructure.ViewNode): String = listOfNotNull(
        node.hint,
        node.idEntry,
        node.contentDescription?.toString(),
        htmlAttribute(node, "name"),
        htmlAttribute(node, "id"),
        htmlAttribute(node, "placeholder"),
        htmlAttribute(node, "autocomplete"),
    ).joinToString(" ")

    /** The words in [text]: split at anything not a letter or digit, and
     * where camelCase changes case ("loginPassword" is "login password"). */
    internal fun words(text: String): List<String> =
        text.replace(Regex("([a-z0-9])([A-Z])"), "$1 $2")
            .lowercase()
            .split(Regex("[^a-z0-9]+"))
            .filter { it.isNotEmpty() }

    /**
     * Whether a [needles] entry is one of the words of [text], or two or
     * three of them run together ("user_name" and "user name" are both
     * "username").
     */
    internal fun matchesWord(text: String, needles: Set<String>): Boolean {
        val words = words(text)
        val joined = buildSet {
            for (i in words.indices) {
                add(words[i])
                if (i + 1 < words.size) add(words[i] + words[i + 1])
                if (i + 2 < words.size) add(words[i] + words[i + 1] + words[i + 2])
            }
        }
        return needles.any { needle ->
            needle.lowercase().replace(Regex("[^a-z0-9]"), "") in joined
        }
    }
}
