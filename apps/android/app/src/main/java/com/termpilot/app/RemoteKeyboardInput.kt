package com.termpilot.app

import android.content.Context
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.TextAttribute
import android.widget.EditText
import androidx.annotation.RequiresApi

/** Keeps IME composition local and forwards only committed text to the desktop. */
internal class RemoteKeyboardInput(
    context: Context,
    private val sendText: (String) -> Unit,
    private val sendKey: (Int) -> Unit,
) : EditText(context) {
    private var changing = 0
    private var batching = 0
    private val composing get() = BaseInputConnection.getComposingSpanStart(text) >= 0

    init {
        hint = tr("提交的文字直接发送到远端")
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(value: Editable?) = flushCommittedText()
        })
    }

    private fun flushCommittedText() {
        if (changing != 0 || batching != 0 || composing || text.isEmpty()) return
        val committed = text.toString()
        changing++
        try { text.clear() } finally { changing-- }
        sendText(committed)
    }

    private inline fun edit(action: () -> Boolean): Boolean {
        changing++
        return try { action() } finally { changing--; flushCommittedText() }
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val base = super.onCreateInputConnection(outAttrs) ?: return null
        return object : InputConnectionWrapper(base, false) {
            override fun beginBatchEdit(): Boolean { batching++; return super.beginBatchEdit() }
            override fun endBatchEdit(): Boolean {
                val result = super.endBatchEdit()
                batching = (batching - 1).coerceAtLeast(0)
                flushCommittedText()
                return result
            }
            override fun setComposingText(value: CharSequence?, newCursorPosition: Int) = edit {
                super.setComposingText(value, newCursorPosition)
            }
            override fun commitText(value: CharSequence?, newCursorPosition: Int) = edit {
                super.commitText(value, newCursorPosition)
            }
            @RequiresApi(33)
            override fun setComposingText(value: CharSequence, newCursorPosition: Int, attribute: TextAttribute?) = edit {
                super.setComposingText(value, newCursorPosition, attribute)
            }
            @RequiresApi(33)
            override fun commitText(value: CharSequence, newCursorPosition: Int, attribute: TextAttribute?) = edit {
                super.commitText(value, newCursorPosition, attribute)
            }
            // Some IMEs only remove composing spans, without a TextWatcher notification.
            override fun finishComposingText() = edit { super.finishComposingText() }
            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (deleteRemote(beforeLength, afterLength)) return true
                return edit { super.deleteSurroundingText(beforeLength, afterLength) }
            }
            override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean {
                if (deleteRemote(beforeLength, afterLength)) return true
                return edit { super.deleteSurroundingTextInCodePoints(beforeLength, afterLength) }
            }
            override fun performEditorAction(actionCode: Int): Boolean {
                if (actionCode in listOf(EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_GO,
                        EditorInfo.IME_ACTION_SEND, EditorInfo.IME_ACTION_NEXT)) {
                    finishComposingText()
                    sendKey(0xff0d)
                    return true
                }
                return super.performEditorAction(actionCode)
            }
        }
    }

    private fun deleteRemote(before: Int, after: Int): Boolean {
        if (composing || text.isNotEmpty() || before < 0 || after < 0) return false
        // IMEs may delete via InputConnection and never emit KEYCODE_DEL.
        repeat(before.coerceAtMost(32768)) { sendKey(0xff08) }
        repeat(after.coerceAtMost(32768)) { sendKey(0xffff) }
        return true
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (!composing && text.isEmpty()) {
            specialKey(keyCode)?.let { sendKey(it); return true }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (specialKey(keyCode) != null) return true
        return super.onKeyUp(keyCode, event)
    }

    private fun specialKey(code: Int): Int? = when (code) {
        KeyEvent.KEYCODE_DEL -> 0xff08
        KeyEvent.KEYCODE_FORWARD_DEL -> 0xffff
        KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> 0xff0d
        KeyEvent.KEYCODE_TAB -> 0xff09
        KeyEvent.KEYCODE_ESCAPE -> 0xff1b
        KeyEvent.KEYCODE_DPAD_LEFT -> 0xff51
        KeyEvent.KEYCODE_DPAD_UP -> 0xff52
        KeyEvent.KEYCODE_DPAD_RIGHT -> 0xff53
        KeyEvent.KEYCODE_DPAD_DOWN -> 0xff54
        else -> null
    }
}
