package com.termpilot.app

import android.content.Context
import android.os.IBinder
import android.view.View
import android.view.ViewTreeObserver
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/** A remote surface with an attached, visually hidden editor for the system IME. */
internal class RemoteKeyboardHost(
    context: Context,
    val surface: View,
    sendText: (String) -> Unit,
    sendKey: (Int) -> Unit,
    private val keyboardChanged: (Boolean) -> Unit,
) : FrameLayout(context) {
    private val editor = RemoteKeyboardInput(context, sendText, sendKey).apply {
        background = null
        hint = null
        setPadding(0, 0, 0, 0)
        alpha = 0f
        isCursorVisible = false
        isFocusable = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
    }
    private var requested = false
    private var wasVisible = false
    private var attachedWindow: IBinder? = null
    private val keyboard get() = context.getSystemService(InputMethodManager::class.java)
    private val layoutListener = ViewTreeObserver.OnGlobalLayoutListener { observeKeyboard() }

    init {
        addView(surface, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        // Must remain attached and VISIBLE for InputMethodManager; no dialog or input row.
        addView(editor, LayoutParams(1, 1))
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets -> observeKeyboard(); insets }
    }

    fun toggleKeyboard() {
        if (requested) hideKeyboard() else {
            requested = true
            keyboardChanged(true)
            // RemoteCanvas requests focus on touch. Keep the IME editor focused
            // so tapping another remote field does not dismiss the keyboard.
            surface.isFocusable = false
            editor.isFocusableInTouchMode = true
            editor.requestFocus()
            editor.post {
                if (requested && isAttachedToWindow && editor.hasFocus())
                    keyboard.showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
            }
        }
    }

    fun hideKeyboard() {
        val ownedFocus = editor.hasFocus()
        val shouldHide = requested || ownedFocus
        requested = false
        wasVisible = false
        keyboardChanged(false)
        // Compose can detach the editor before onRelease, clearing its focus/token.
        if (shouldHide) keyboard.hideSoftInputFromWindow(editor.windowToken ?: attachedWindow, 0)
        editor.clearFocus()
        editor.isFocusable = false
        surface.isFocusableInTouchMode = true
        if (ownedFocus && isAttachedToWindow) surface.requestFocus()
    }

    private fun observeKeyboard() {
        if (!requested) return
        val visible = ViewCompat.getRootWindowInsets(this)?.isVisible(WindowInsetsCompat.Type.ime()) == true
        if (visible) wasVisible = true
        else if (wasVisible) hideKeyboard() // System Back / the IME's own hide button.
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        attachedWindow = windowToken
        viewTreeObserver.addOnGlobalLayoutListener(layoutListener)
    }

    override fun onDetachedFromWindow() {
        viewTreeObserver.removeOnGlobalLayoutListener(layoutListener)
        hideKeyboard()
        attachedWindow = null
        super.onDetachedFromWindow()
    }
}
