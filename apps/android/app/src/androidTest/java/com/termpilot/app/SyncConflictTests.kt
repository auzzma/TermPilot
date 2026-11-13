package com.termpilot.app
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
class SyncConflictTests {
    @get:Rule val compose=createComposeRule()
    private fun conflict(secret:Boolean=false):JSONObject {
        fun candidate(i:Int)=obj("dot" to obj("writer" to "device-$i","seq" to 1),"display" to if(secret)"敏感内容已隐藏" else "host-$i.invalid","secret" to secret,"source" to obj("name" to "设备 $i","at" to "2026-11-13T00:00:00Z","local" to (i==1)))
        return obj("id" to "hosts/fixture","scope" to if(secret)"credentials" else "configuration","title" to "主机：开发服务器","subtitle" to "fixture.invalid:22","revision" to "fixture-revision","deleted" to false,
            "details" to JSONArray().put(obj("key" to if(secret)"password" else "hostname","label" to if(secret)"登录密码" else "主机地址 / IP","hint" to "请选择保留的版本","candidates" to JSONArray().put(candidate(1)).put(candidate(2)))))
    }
    @Test fun compareThenSelectSendsOnlyChosenVersionAndRevision() {
        var saved:JSONObject?=null
        compose.setContent{MaterialTheme{Column(Modifier.verticalScroll(rememberScrollState())){SyncConflicts(listOf(conflict()),true,{obj()}){_,command->saved=command}}}}
        compose.onNodeWithText("主机：开发服务器").performClick()
        compose.onNodeWithTag("sync-conflict-save").performScrollTo().assertIsNotEnabled()
        compose.onAllNodesWithText("选择此版本")[1].performScrollTo().performClick()
        compose.onNodeWithTag("sync-conflict-save").performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle{assertEquals("device-2",saved!!.getJSONObject("choices").getJSONObject("hostname").getString("writer"));assertEquals("fixture-revision",saved!!.getString("revision"));assertFalse(saved!!.toString().contains("host-2.invalid"))}
    }
    @Test fun sensitiveValuesRequireExplicitRevealAndCollapseClearsThem() {
        var reads=0
        compose.setContent{MaterialTheme{Column(Modifier.verticalScroll(rememberScrollState())){SyncConflicts(listOf(conflict(true)),true,{command->assertTrue(command.getBoolean("reveal"));reads++;obj("display" to "fixture-visible-secret")}){_,_->}}}}
        compose.onNodeWithText("主机：开发服务器").performClick()
        compose.onNodeWithText("fixture-visible-secret").assertDoesNotExist()
        compose.onAllNodesWithText("显示敏感内容")[0].performScrollTo().performClick()
        compose.waitUntil(3000){reads==1}
        compose.onNodeWithText("fixture-visible-secret").assertExists()
        compose.onNodeWithText("主机：开发服务器").performScrollTo().performClick()
        compose.onNodeWithText("fixture-visible-secret").assertDoesNotExist()
        compose.onNodeWithText("主机：开发服务器").performClick()
        compose.onNodeWithText("fixture-visible-secret").assertDoesNotExist()
    }
}
