package com.termpilot.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import kotlinx.coroutines.*
import org.json.JSONArray

class InterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Before fun prepare(){
        compose.waitUntil(15000){compose.activity.mobileModel.ready}
        compose.runOnIdle{compose.activity.mobileModel.chooseLanguage("zh-Hans");compose.activity.mobileModel.appearance(theme="dark");compose.activity.mobileModel.selected=null}
    }
    private fun settings(){compose.onNodeWithTag("home-settings").performClick()}
    private fun back(){compose.onAllNodes(hasContentDescription("返回") or hasContentDescription("取消")).onLast().performClick()}
    @Test fun aboutLicenseOpensAndClosesAsModal(){
        settings();compose.onNodeWithText("关于 TermPilot").performScrollTo().performClick()
        repeat(2){iteration->
            compose.onNodeWithText("GNU General Public License v3.0").performScrollTo().performClick()
            compose.onNodeWithTag("gpl-license-text").assertTextContains("Version 3, 29 June 2007",substring=true)
                .assertTextContains("END OF TERMS AND CONDITIONS",substring=true)
                .assertTextContains("https://www.gnu.org/licenses/why-not-lgpl.html",substring=true)
            if(iteration==0)screenshot("about-gpl-license")
            compose.onNodeWithTag("close-gpl-license").performClick()
            compose.onNodeWithTag("gpl-license-text").assertDoesNotExist()
            compose.onNodeWithText("应用名称").assertExists()
        }
    }
    @Test fun dataSyncProviderForm(){
        settings();compose.onNodeWithText("数据同步").performScrollTo().performClick()
        compose.waitUntil(15000){compose.onAllNodesWithText("添加云服务").fetchSemanticsNodes().isNotEmpty()}
        compose.onNodeWithText("添加云服务").performScrollTo().performClick()
        compose.onNodeWithText("服务类型").performScrollTo().performClick();compose.onNodeWithText("S3 / S3 Compatible").performClick()
        compose.onNodeWithText("HTTPS Endpoint").assertExists()
        compose.onNodeWithText("服务类型").performScrollTo().performClick();compose.onNodeWithText("Cloudflare R2").performClick()
        compose.onNodeWithText("R2 S3 API Endpoint").assertExists()
        compose.onNodeWithText("Region").assertDoesNotExist()
        screenshot("data-sync-r2")
        compose.onNodeWithText("服务类型").performScrollTo().performClick();compose.onNodeWithText("WebDAV").performClick()
        compose.onNodeWithText("认证方式").assertExists()
        compose.onNodeWithText("R2 S3 API Endpoint").assertDoesNotExist()
        screenshot("data-sync-form")
    }
    @Test fun groupedSettingsAndTheme(){
        settings();compose.onAllNodesWithText("通用").onFirst().assertIsDisplayed();compose.onNodeWithText("AI").assertIsDisplayed();screenshot("settings-dark")
        compose.onAllNodesWithText("通用").onFirst().performClick();compose.onNodeWithText("外观").performClick()
        compose.onNodeWithText("浅色").performClick();compose.runOnIdle{assertTrue(androidx.core.view.WindowCompat.getInsetsController(compose.activity.window,compose.activity.window.decorView).isAppearanceLightStatusBars)};screenshot("appearance-light")
        compose.onNodeWithText("深色").performClick();back()
        compose.onNodeWithText("终端").performClick();compose.onNodeWithText("快捷键栏").performScrollTo().performClick()
        compose.onNodeWithText("Esc").assertIsDisplayed();screenshot("shortcuts");back();back()
        compose.onNodeWithText("远程桌面帧率上限").performClick();compose.onNodeWithText("30 FPS").performClick()
        compose.runOnIdle{assertEquals(30,compose.activity.mobileModel.fps)}
        compose.onNodeWithText("60 FPS").performClick()
    }
    @Test fun videoCodecSettingPersists(){
        settings();compose.onAllNodesWithText("通用").onFirst().performClick();compose.onNodeWithText("终端").performClick()
        compose.onNodeWithText("Apple 高性能视频编码").performScrollTo().performClick()
        compose.onNodeWithText("H.265").performClick()
        compose.waitUntil(5000){compose.activity.mobileModel.videoCodec=="h265"}
        compose.runOnIdle{assertEquals("h265",compose.activity.getSharedPreferences("TermPilot",0).getString("videoCodec",null))}
        screenshot("video-codec-h265");compose.onNodeWithText("H.264").performClick()
        compose.waitUntil(5000){compose.activity.mobileModel.videoCodec=="h264"}
        back();compose.onNodeWithText("H.264").assertExists()
    }
    @Test fun aiSettingsPages(){
        settings();compose.onNodeWithText("AI").performClick()
        compose.waitUntil(10000){compose.onAllNodesWithText("行为与安全").fetchSemanticsNodes().isNotEmpty()};screenshot("ai-settings")
        compose.onNodeWithText("行为与安全").performClick();compose.onNodeWithContentDescription("最大工具轮次 +").performClick();compose.onNodeWithContentDescription("最大工具轮次 −").performClick();compose.onNodeWithText("命令黑名单 · 每行一条正则表达式").assertExists();screenshot("ai-safety");back()
        compose.onNodeWithText("网络搜索").performClick();compose.onNodeWithText("启用网络搜索").assertExists();back()
        compose.onNodeWithText("提供商").performClick();compose.onNodeWithText("新增提供商").performClick()
        compose.onNodeWithContentDescription("Base URL").assertExists();compose.onNodeWithText("默认模型").performScrollTo().assertExists();screenshot("provider");back();back()
        compose.onNodeWithText("Agent").performClick();compose.onNodeWithText("仅桌面端").assertExists()
    }
    @Test fun quickConnectChangesProtocolAndKeepsEnteredHost(){
        screenshot("hosts");compose.onNodeWithText("快速连接").performClick()
        compose.onNodeWithContentDescription("IP 地址 / 主机名").performTextInput("example.invalid")
        compose.onNodeWithText("连接类型").performClick();compose.onNodeWithText("RDP").performClick()
        compose.onNodeWithText("3389").assertExists();compose.onNodeWithText("example.invalid").assertExists()
        compose.onNodeWithText("名称").assertDoesNotExist();screenshot("quick-connect-rdp")
        compose.onNodeWithText("代理").performScrollTo().assertExists();back()
        compose.onNodeWithContentDescription("新增主机").performClick();compose.onNodeWithText("名称").assertExists();screenshot("add-host")
    }
    @Test fun languageRemainsUsable(){
        settings();compose.onAllNodesWithText("通用").onFirst().performClick();compose.onNodeWithText("语言").performClick();compose.onNodeWithText("English").performClick()
        compose.onNodeWithTag("home-settings").performClick();compose.onAllNodesWithText("General").onFirst().performClick();compose.onNodeWithText("Language").performClick()
        compose.onNodeWithText("简体中文").performClick();compose.onNodeWithTag("home-settings").performClick();compose.onAllNodesWithText("通用").onFirst().assertIsDisplayed()
    }
    @Test fun chatAndToolsReturnToSameSession(){
        val model=compose.activity.mobileModel
        val session=Session(0,obj("id" to "ui-fixture","label" to "UI Preview","hostname" to "preview.invalid","username" to "demo"),"ssh","")
        compose.runOnIdle{model.sessions.add(session)}
        runBlocking{withContext(Dispatchers.Main){withTimeout(15000){model.openAI(session)}}}
        compose.runOnIdle{
            session.conversation=obj("id" to session.conversation.optString("id"),"messages" to JSONArray(listOf(
                obj("role" to "user","content" to "服务器还剩多少磁盘空间？"),
                obj("role" to "assistant","content" to "以下为界面测试示例。","calls" to JSONArray(listOf(obj("name" to "terminal_execute","arguments" to obj("command" to "df -h"))))),
                obj("role" to "tool","content" to "Filesystem  Size  Used  Avail\n/dev/vda1   20G   6.8G  13G"),
                obj("role" to "assistant","content" to "## 磁盘空间\n\n| 分区 | 总容量 | 剩余 |\n| --- | --- | --- |\n| `/` | 20 GB | 13 GB |\n\n可用空间充足。")
            )))
            session.activePanel="ai";model.selected=session.id
        }
        // This offline fixture has no terminal channel. Wide layouts resize their
        // terminal placeholder; dismiss only that expected fixture error.
        fun settleOfflinePreview(){
            compose.waitForIdle()
            compose.runOnIdle{val error=model.error;assertTrue(error==null || error=="Terminal session is closed.");if(error=="Terminal session is closed.")model.error=null}
        }
        settleOfflinePreview()
        compose.onNodeWithText("服务器还剩多少磁盘空间？").assertIsDisplayed()
        val bubble=compose.onNodeWithTag("ai-user-bubble").fetchSemanticsNode().boundsInRoot
        val conversation=compose.onNodeWithTag("ai-conversation").fetchSemanticsNode().boundsInRoot
        assertTrue("User messages stay at the trailing edge",bubble.center.x>conversation.center.x)
        assertTrue("Trailing inset is smaller than the leading space",conversation.right-bubble.right<bubble.left-conversation.left)
        screenshot("chat-dark")
        compose.runOnIdle{model.theme="light"};settleOfflinePreview();screenshot("chat-light")
        compose.onNodeWithTag("workspace-tools").performClick();compose.onNodeWithTag("tools-back").assertIsDisplayed();settleOfflinePreview();screenshot("overview-preserved")
        compose.onNodeWithTag("tools-back").performClick();compose.onNodeWithText("服务器还剩多少磁盘空间？").assertIsDisplayed()
        compose.runOnIdle{model.selected=null;model.sessions.remove(session);model.theme="dark"}
    }
    @Test fun recordEditorsKeepDraftsLocal(){
        val model=compose.activity.mobileModel
        val originalCredentials=model.records["credentials"]?.size?:0
        settings();compose.onNodeWithText("凭证与密钥").performClick();compose.onNodeWithText("新增").performClick()
        compose.onNodeWithContentDescription("名称").performTextInput("UI draft")
        compose.onNodeWithText("类型").performClick();compose.onNodeWithText("私钥").performClick()
        compose.onNodeWithContentDescription("私钥").performScrollTo().performTextInput("test-only draft")
        compose.onNodeWithContentDescription("私钥口令").performScrollTo().assertExists();screenshot("credential");back();back()
        compose.runOnIdle{assertEquals(originalCredentials,model.records["credentials"]?.size?:0)}
        compose.onNodeWithText("代理配置").performClick();compose.onNodeWithText("新增").performClick()
        compose.onNodeWithText("代理类型").performClick();compose.onNodeWithText("HTTP CONNECT").performClick()
        compose.onNodeWithContentDescription("主机").performTextInput("proxy.invalid");screenshot("proxy");back();back()
        compose.onNodeWithText("工具与快捷键").performClick();compose.onNodeWithText("脚本").performClick();compose.onNodeWithText("新增").performClick()
        compose.onNodeWithContentDescription("标题").performTextInput("UI script")
        compose.onNodeWithContentDescription("内容").performScrollTo().performTextInput("echo preview")
        screenshot("script");back();back()
        // A tablet keeps SettingsHome visible; only a phone pushes the tools page.
        if(compose.activity.resources.configuration.screenWidthDp<760)back()
        compose.onNodeWithText("备份与恢复").performScrollTo().performClick()
        compose.onNodeWithContentDescription("备份密码").assertExists();screenshot("backup")
    }
    private fun screenshot(name:String){
        compose.waitForIdle();Thread.sleep(350)
        val instrument=InstrumentationRegistry.getInstrumentation();val image=instrument.uiAutomation.takeScreenshot()
        File(instrument.targetContext.cacheDir,"ui-$name.png").outputStream().use{image.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};image.recycle()
    }
}
