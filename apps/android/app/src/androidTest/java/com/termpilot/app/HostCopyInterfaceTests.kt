package com.termpilot.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import java.util.UUID

class HostCopyInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun longPressCopyCanCancelOrEditAndSaveWithoutChangingSource(){
        compose.waitUntil(15000){compose.activity.mobileModel.ready}
        val model=compose.activity.mobileModel
        val runtime=model.runtime!!
        val label="Copy UI ${UUID.randomUUID()}"
        val edited="$label saved"
        fun call(request:org.json.JSONObject)=runBlocking{runtime.call(request)}
        val host=call(obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to label,"hostname" to "fixture.invalid","port" to 22,"username" to "fixture","connectionKind" to "ssh","authentication" to "password"))).getJSONObject("item")
        val records=model.records["hosts"].orEmpty()
        try{
            compose.runOnIdle{model.selected=null;model.records["hosts"]=listOf(host)}
            compose.onNodeWithTag("home-hosts").performClick()
            compose.onNodeWithText("全部展开").performClick()
            compose.onNodeWithText(label).performTouchInput{longClick()}
            compose.onNodeWithText("复制主机").performClick()
            compose.waitUntil(5000){compose.onAllNodesWithText("$label 副本").fetchSemanticsNodes().isNotEmpty()}
            compose.onNodeWithText("取消").performClick()
            assertEquals(1,call(obj("method" to "vault.list","collection" to "hosts")).objects("items").count{it.optString("label").startsWith(label)})
            compose.onNodeWithText(label).performTouchInput{longClick()}
            compose.onNodeWithText("复制主机").performClick()
            compose.waitUntil(5000){compose.onAllNodesWithText("$label 副本").fetchSemanticsNodes().isNotEmpty()}
            compose.onNode(hasSetTextAction() and hasText("$label 副本")).performTextReplacement(edited)
            compose.onNodeWithText("保存").performClick()
            compose.waitUntil(8000){model.records["hosts"].orEmpty().any{it.optString("label")==edited}}
            val saved=call(obj("method" to "vault.list","collection" to "hosts")).objects("items")
            assertEquals(2,saved.count{it.optString("label").startsWith(label)})
            assertEquals(label,saved.first{it.optString("id")==host.optString("id")}.optString("label"))
        }finally{
            call(obj("method" to "vault.list","collection" to "hosts")).objects("items").filter{it.optString("label").startsWith(label)}.forEach{call(obj("method" to "vault.delete","collection" to "hosts","id" to it.optString("id")))}
            compose.runOnIdle{model.records["hosts"]=records}
        }
    }
}
