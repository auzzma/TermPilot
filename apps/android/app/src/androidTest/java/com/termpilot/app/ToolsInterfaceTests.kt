package com.termpilot.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

class ToolsInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    private val context get()=InstrumentationRegistry.getInstrumentation().targetContext
    private fun <T> main(block:suspend ()->T):T=runBlocking { withContext(Dispatchers.Main){block()} }
    private fun shot(name:String){
        compose.waitForIdle();Thread.sleep(350)
        val image=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.cacheDir,"ui-$name.png").outputStream().use{image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};image.recycle()
    }
    @Test fun largeControlPacketAndTruncatedPacket(){
        val output="process 中文\n".repeat(10000)
        val json=obj("type" to "sftpResponse","stdout" to output).toString().toByteArray()
        val bytes=java.nio.ByteBuffer.allocate(4+json.size+2).putInt(json.size).put(json).put(byteArrayOf(1,2)).array()
        assertEquals(output,decodeMobilePacket(bytes).header.getString("stdout"))
        assertArrayEquals(byteArrayOf(1,2),decodeMobilePacket(bytes).payload)
        assertTrue(runCatching{decodeMobilePacket(bytes.copyOf(100))}.isFailure)
    }
    @Test fun counterDeltasResetAndProcessNames(){
        val parser=MonitorParser()
        fun sample(t:Int,raw:String,rx:Int,tx:Int)="SAMPLE_TIME=$t\nMEM_TOTAL_MB=1024\nMEM_USED_MB=256\nCPU_RAW=$raw\nNETIF_BYTES=eth0|$rx|$tx\nDISK=/|4|20|20\nTOPPROC=7|25|my process"
        val first=parser.parse(sample(100,"1000|700|200|100",1000,2000))
        assertNull(first.metric("cpuUsage"));assertNull(first.metric("networkRxPerSecond"))
        val next=parser.parse(sample(103,"1300|880|290|130",4072,3536))
        assertEquals(40.0,next.metric("cpuUsage")!!,.001);assertEquals(1024.0,next.metric("networkRxPerSecond")!!,.001)
        assertEquals(30.0,next.metric("cpuUserUsage")!!,.001);assertEquals(512.0,next.metric("networkTxPerSecond")!!,.001)
        assertEquals(268435456.0,next.metric("memoryUsed")!!,.001)
        val reset=parser.parse(sample(106,"100|70|20|10",10,20))
        assertNull(reset.metric("cpuUsage"));assertNull(reset.metric("networkRxPerSecond"))
        assertEquals("/path/My App",MonitorParser.processes(" 42 root 1.2 3.4 1024 /path/My App").single().optString("command"))
        assertTrue(runCatching{parser.parse("not a monitor response")}.isFailure)
    }
    @Test fun liveToolsNavigationFullScreenEditorAndMonitoring(){
        val fixture=File(context.cacheDir,"mobile-fixture.json");assumeTrue("No authorized fixture",fixture.exists())
        val source=JSONObject(fixture.readText());val host=LiveTestFixture.host(source, "tools");val model=compose.activity.mobileModel
        var s:Session?=null;var root="";var known:File?=null;var original:ByteArray?=null
        try {
            main {
                withTimeout(15000){while(!model.ready)delay(30)}
                model.chooseLanguage("zh-Hans");model.theme="dark"
                known=File(model.runtime!!.directory,"known_hosts");original=known!!.takeIf{it.exists()}?.readBytes();known!!.writeText(source.getString("knownHosts"))
                model.connect(JSONObject(host.toString()).put("connectionKind","ssh").put("label","工具界面验收"))
                s=checkNotNull(model.current);withTimeout(45000){while(!s!!.filesReady||!s!!.execReady)delay(30)}
                root=model.files(s!!,obj("action" to "realpath","path" to ".")).getString("path")+"/TermPilot-tools-${UUID.randomUUID()}"
                File(context.cacheDir,"tools-test-directory.txt").writeText(root)
                model.files(s!!,obj("action" to "mkdir","path" to root))
                model.files(s!!,obj("action" to "writeText","path" to "$root/editor-中文.txt","content" to "original\n","overwrite" to false))
                model.list(s!!,root)
                val data=model.exec(s!!,context.assets.open("monitor.sh").bufferedReader().use{it.readText()})
                assertEquals(data.optString("stderr"),0,data.optInt("code"))
                assertTrue(MonitorParser().parse(data.getString("stdout")).metric("memoryTotal")!!>0)
            }
            compose.onNodeWithTag("workspace-tools").performClick()
            compose.onNodeWithTag("tools-page").assertExists()
            compose.onNodeWithTag("tool-forwards").assertIsDisplayed()
            compose.onNodeWithTag("workspace-terminal").assertDoesNotExist()
            compose.waitUntil(15000){compose.onAllNodesWithText("每 3 秒更新").fetchSemanticsNodes().isNotEmpty()}
            compose.waitUntil(15000) {
                compose.mainClock.advanceTimeBy(100)
                compose.onAllNodesWithText("/s",substring=true).fetchSemanticsNodes().isNotEmpty()
            }
            shot("tools-monitor-dark")
            compose.runOnIdle{model.theme="light"};shot("tools-monitor-light")
            compose.onNodeWithTag("tool-section-processes").performClick()
            compose.waitUntil(15000){compose.onAllNodesWithText("PID ",substring=true).fetchSemanticsNodes().isNotEmpty()}
            shot("tools-processes")
            compose.onNodeWithTag("tool-files").performClick()
            compose.onNodeWithText("editor-中文.txt").assertIsDisplayed()
            compose.onNodeWithContentDescription("操作").performClick()
            compose.onNodeWithText("编辑文本").performClick()
            compose.waitUntil(10000){compose.onAllNodesWithText("original\n").fetchSemanticsNodes().isNotEmpty()}
            val page=compose.onNodeWithTag("file-editor-page").fetchSemanticsNode().boundsInRoot
            val editor=compose.onNodeWithTag("file-editor-text").fetchSemanticsNode().boundsInRoot
            assertTrue("Editor should fill usable height",editor.height>page.height*.55f)
            compose.onNodeWithTag("file-editor-text").performTextReplacement("changed 中文\n")
            compose.onNodeWithContentDescription("返回").performClick()
            compose.onNodeWithText("继续编辑").performClick()
            shot("editor-fullscreen")
            compose.onNodeWithText("保存").performClick()
            compose.waitUntil(10000){compose.onAllNodesWithTag("file-editor-page").fetchSemanticsNodes().isEmpty()}
            main{assertEquals("changed 中文\n",model.files(s!!,obj("action" to "readText","path" to "$root/editor-中文.txt")).getString("text"))}
            compose.onNodeWithTag("tools-back").performClick()
            compose.onNodeWithTag("workspace-terminal").assertIsDisplayed()
            compose.onNodeWithTag("workspace-ai").performClick()
            compose.onNodeWithTag("workspace-tools").performClick()
            compose.onNodeWithTag("tools-back").performClick()
            main{assertEquals("ai",s!!.activePanel)}
        } finally {
            main{ withTimeout(10000) { s?.let{if(root.isNotEmpty())runCatching{model.files(it,obj("action" to "delete","path" to root))};runCatching{model.close(it)}}
                if(original!=null)known?.writeBytes(original!!)else known?.delete();model.theme="dark"
            } };fixture.delete()
        }
    }
}
