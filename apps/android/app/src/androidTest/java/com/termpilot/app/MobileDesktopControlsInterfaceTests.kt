package com.termpilot.app

import androidx.activity.ComponentActivity
import androidx.compose.material3.Surface
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import android.graphics.Bitmap

class MobileDesktopControlsInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<ComponentActivity>()
    @Test fun capabilityControlsMenuAndCancellationStaysReachable(){
        val s=Session(990,obj("mode" to "standardVNC"),"screen","")
        val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
        compose.runOnIdle{s.connected=true;s.desktopControls.available={true};s.desktopControls.keyTimeout=5000;s.desktopControls.send={}}
        compose.setContent{MobileTheme(true){Surface{
            RemoteActionBar(false,false,false,true,TerminalKey.ordered(TerminalKey.defaultOrder),onAction={},onShortcut={},trailingActions={
                MobileDesktopActions(s,true,login={scope.launch{s.desktopControls.login{"fixture"}}},resize={v->scope.launch{s.desktopControls.resizeVNC(v)}})
            })
        }}}
        compose.onNodeWithTag("remote-resolution").performScrollTo()
        compose.onNodeWithTag("remote-login-password").assertIsEnabled().assertIsDisplayed()
        val audio=compose.onNodeWithTag("remote-action-audio").fetchSemanticsNode().boundsInRoot
        val login=compose.onNodeWithTag("remote-login-password").fetchSemanticsNode().boundsInRoot
        val resolution=compose.onNodeWithTag("remote-resolution").fetchSemanticsNode().boundsInRoot
        assertEquals(audio.center.y,login.center.y,1f);assertEquals(login.center.y,resolution.center.y,1f)
        assertTrue(audio.left<login.left);assertTrue(login.left<resolution.left)
        compose.onNodeWithTag("remote-login-status").assertDoesNotExist()
        compose.onNodeWithTag("remote-resolution-status").assertDoesNotExist()
        val bitmap=compose.onNodeWithTag("remote-action-bar").captureToImage().asAndroidBitmap()
        File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"mobile-inline-toolbar.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
        compose.onNodeWithTag("remote-resolution").performClick()
        compose.onNodeWithText("1280 × 720").assertIsNotEnabled()
        compose.onAllNodesWithText("远端未提供分辨率调整能力，请在远端系统设置中修改。").assertCountEquals(0)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.runOnIdle{s.desktopControls.receive(obj("kind" to "vncCapabilities","canResize" to true))}
        compose.onNodeWithTag("remote-resolution").performClick()
        compose.onNodeWithText("1280 × 720").assertIsEnabled()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        compose.onNodeWithTag("remote-login-password").performClick()
        compose.onNodeWithTag("remote-login-cancel").performScrollTo().assertIsDisplayed().performClick()
        compose.waitUntil{!s.desktopControls.loginBusy}
        compose.runOnIdle{assertEquals("已取消密码输入。",s.desktopControls.loginMessage);assertNull(s.desktopControls.actionError)}
        // Errors are presented on demand, without restoring a permanent caption row.
        compose.runOnIdle{s.desktopControls.actionError="远端服务不允许修改分辨率。"}
        compose.onNodeWithText("操作失败").assertIsDisplayed()
        compose.onNodeWithText("远端服务不允许修改分辨率。").assertIsDisplayed()
        compose.onNodeWithText("关闭").performClick()
        compose.runOnIdle{s.desktopControls.stop();scope.cancel()}
    }
    @Test fun highPerformanceOffersPresetsWithoutVncExtension(){
        val s=Session(991,obj("mode" to "highPerformance"),"screen","");var chosen:DesktopResolution?=null
        compose.setContent{MobileTheme(false){Surface{
            RemoteActionBar(false,false,false,true,TerminalKey.ordered(TerminalKey.defaultOrder),onAction={},onShortcut={},trailingActions={MobileDesktopActions(s,true,login={},resize={chosen=it})})
        }}}
        compose.onNodeWithTag("remote-resolution").performScrollTo().performClick()
        compose.onNodeWithText("修改分辨率会重新连接当前会话。").assertDoesNotExist()
        compose.onNodeWithText("2560 × 1440").assertIsEnabled().performClick()
        compose.runOnIdle{assertEquals(DesktopResolution(2560,1440),chosen)}
    }
}
