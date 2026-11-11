package com.termpilot.app

import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.graphics.Bitmap
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowCompat
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

class RemoteKeyboardInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()

    @Test fun keyboardShowsInlineKeepsRemoteTouchFocusAndClosesWithPage() {
        lateinit var host:RemoteKeyboardHost
        var selected by mutableStateOf(false)
        var showSurface by mutableStateOf(true)
        var dark by mutableStateOf(true)
        val committed=mutableListOf<String>()
        val keys=mutableListOf<Int>()
        compose.setContent {
            MobileTheme(dark){Surface{Column(Modifier.fillMaxSize().imePadding()) {
                if(showSurface) AndroidView(factory={context->
                    val desktop=object:View(context){
                        init {isFocusableInTouchMode=true}
                        override fun onTouchEvent(event:MotionEvent):Boolean {requestFocus();return true}
                    }
                    RemoteKeyboardHost(context,desktop,{committed.add(it)},{keys.add(it)},{selected=it}).also{host=it}
                },onRelease={it.hideKeyboard()},modifier=Modifier.weight(1f).fillMaxWidth().testTag("remote-desktop"))
                Box(Modifier.testTag("remote-toolbar")){
                    RemoteActionBar(false,selected,false,true,TerminalKey.ordered(TerminalKey.defaultOrder),onAction={if(it==RemoteAction.Keyboard)host.toggleKeyboard()},onShortcut={})
                }
            }}}
        }
        fun captureToolbar(name:String){
            val bitmap=compose.onNodeWithTag("remote-toolbar").captureToImage().asAndroidBitmap()
            File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"remote-toolbar-$name.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
        }
        captureToolbar("dark")
        compose.runOnIdle{dark=false}
        captureToolbar("light")
        compose.runOnIdle{dark=true}
        val originalHeight=compose.runOnIdle{host.height}
        fun imeVisible():Boolean {
            var visible=false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                visible=ViewCompat.getRootWindowInsets(compose.activity.window.decorView)?.isVisible(WindowInsetsCompat.Type.ime())==true
            }
            return visible
        }
        compose.onNodeWithText("键盘").performClick()
        compose.waitUntil(10000){imeVisible()}
        compose.onAllNodes(isDialog()).assertCountEquals(0)
        compose.onNodeWithText("键盘").assertIsSelected()
        captureToolbar("active")
        compose.onNodeWithTag("remote-desktop").performTouchInput {click(center)}
        compose.runOnIdle {
            assertTrue("Remote touch must leave the IME focused",host.findFocus() is RemoteKeyboardInput)
            assertTrue("Keyboard must leave a usable remote surface",host.height in 1 until originalHeight)
            val editor=host.findFocus() as RemoteKeyboardInput
            assertEquals(0f,editor.alpha)
            val connection=editor.onCreateInputConnection(EditorInfo())!!
            connection.setComposingText("中文",1);connection.finishComposingText()
            connection.deleteSurroundingText(1,0)
            assertEquals(listOf("中文"),committed)
            assertEquals(listOf(0xff08),keys)
        }
        compose.onNodeWithText("键盘").performClick()
        compose.waitUntil(10000){!imeVisible()}
        compose.onNodeWithText("键盘").assertIsNotSelected()
        compose.runOnIdle {assertTrue(host.surface.hasFocus())}

        compose.onNodeWithText("键盘").performClick()
        compose.waitUntil(10000){imeVisible()}
        // Same window-insets path used by the system Back / IME hide action.
        compose.runOnIdle {WindowCompat.getInsetsController(compose.activity.window,host).hide(WindowInsetsCompat.Type.ime())}
        compose.waitUntil(10000){!imeVisible()&&!selected}

        compose.onNodeWithText("键盘").performClick()
        compose.waitUntil(10000){imeVisible()}
        compose.runOnIdle {showSurface=false}
        compose.waitUntil(10000){!imeVisible()}
        compose.onAllNodes(isDialog()).assertCountEquals(0)
    }
}
