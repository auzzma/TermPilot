package com.termpilot.app

import android.view.inputmethod.EditorInfo
import android.view.KeyEvent
import android.os.Build
import android.view.inputmethod.TextAttribute
import org.junit.Assume.assumeTrue
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class RemoteKeyboardTests {
    private fun checkInput(block:(RemoteKeyboardInput,MutableList<String>,MutableList<Int>)->Unit) {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val text=mutableListOf<String>();val keys=mutableListOf<Int>()
            val view=RemoteKeyboardInput(instrumentation.targetContext,{text.add(it)},{keys.add(it)})
            block(view,text,keys)
        }
    }

    @Test fun compositionFinishingWithoutTextChangeCommitsOnce()=checkInput {view,text,keys->
        val connection=view.onCreateInputConnection(EditorInfo())!!
        connection.setComposingText("中文",1)
        assertTrue("Uncommitted composition must remain local",text.isEmpty())
        connection.finishComposingText()
        assertEquals(listOf("中文"),text)
        connection.finishComposingText()
        assertEquals("Finishing twice must not duplicate input",listOf("中文"),text)
        assertTrue(keys.isEmpty())
    }

    @Test fun softKeyboardDeletionReachesRemoteWhenLocalBufferIsEmpty()=checkInput {view,text,keys->
        val connection=view.onCreateInputConnection(EditorInfo())!!
        connection.commitText("abc",1)
        assertEquals(listOf("abc"),text)
        connection.deleteSurroundingText(1,0)
        connection.deleteSurroundingTextInCodePoints(1,0)
        connection.deleteSurroundingText(0,1)
        assertEquals(listOf(0xff08,0xff08,0xffff),keys)
    }

    @Test fun compositionEditsStayLocalAndCandidateIsSentOnlyOnce()=checkInput {view,text,keys->
        val connection=view.onCreateInputConnection(EditorInfo())!!
        connection.setComposingText("zhongw",1)
        connection.deleteSurroundingText(1,0)
        assertTrue(keys.isEmpty())
        assertTrue(text.isEmpty())
        connection.setComposingText("中文",1)
        connection.commitText("中文",1)
        connection.finishComposingText()
        assertEquals(listOf("中文"),text)
        assertTrue(view.text.isEmpty())
    }

    @Test fun batchCommitAndSubsequentTypingKeepTextOrder()=checkInput {view,text,keys->
        val connection=view.onCreateInputConnection(EditorInfo())!!
        connection.beginBatchEdit()
        connection.setComposingText("abc",1)
        connection.commitText("A中😀!",1)
        assertTrue(text.isEmpty())
        connection.endBatchEdit()
        connection.commitText("next",1)
        assertEquals(listOf("A中😀!","next"),text)
        assertTrue(keys.isEmpty())
    }

    @Test fun modernIMECompositionAndCommitUseTheSamePath()=checkInput {view,text,keys->
        assumeTrue(Build.VERSION.SDK_INT>=33)
        val connection=view.onCreateInputConnection(EditorInfo())!!
        val attribute=TextAttribute.Builder().build()
        connection.setComposingText("候选",1,attribute)
        assertTrue(text.isEmpty())
        connection.commitText("确认",1,attribute)
        assertEquals(listOf("确认"),text)
        assertTrue(keys.isEmpty())
    }

    @Test fun keyboardEnterTabAndEditorActionSendBalancedActions()=checkInput {view,text,keys->
        val connection=view.onCreateInputConnection(EditorInfo())!!
        for(code in listOf(KeyEvent.KEYCODE_ENTER,KeyEvent.KEYCODE_TAB,KeyEvent.KEYCODE_DEL)) {
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN,code))
            view.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP,code))
        }
        connection.performEditorAction(EditorInfo.IME_ACTION_DONE)
        assertEquals(listOf(0xff0d,0xff09,0xff08,0xff0d),keys)
        assertTrue(text.isEmpty())
    }
}
