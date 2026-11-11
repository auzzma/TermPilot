package com.termpilot.app

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import org.junit.Assert.*
import java.io.File

class HostGroupInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun nestedMenusCollapseSearchAndRestoreOnReturn(){
        compose.waitUntil(15000){compose.activity.mobileModel.ready}
        val model=compose.activity.mobileModel
        val preferences=compose.activity.getSharedPreferences("TermPilot.ui",0)
        val saved=preferences.getStringSet("collapsedHostGroups",emptySet())!!.toSet()
        try {
            compose.runOnIdle{
                model.chooseLanguage("zh-Hans");model.selected=null
                model.records["groups"]=listOf(obj("id" to "tree-root","name" to "Cloud"),obj("id" to "tree-child","name" to "Production","parentGroupID" to "tree-root"),obj("id" to "tree-leaf","name" to "Asia","parentGroupID" to "tree-child"))
                model.records["hosts"]=listOf(obj("id" to "tree-host","label" to "Database","hostname" to "10.0.0.2","groupID" to "tree-leaf"),obj("id" to "loose-host","label" to "Ungrouped host","hostname" to "example.invalid"))
            }
            compose.onNodeWithTag("home-hosts").performClick()
            compose.onNodeWithText("全部展开").performClick()
            compose.onNodeWithTag("host-tree-host").assertExists()
            compose.onNodeWithTag("group-tree-child").performClick()
            compose.onNodeWithTag("group-tree-leaf").assertDoesNotExist()
            compose.onNodeWithTag("host-tree-host").assertDoesNotExist()
            compose.onNodeWithTag("host-loose-host").assertExists()
            compose.onNodeWithTag("home-settings").performClick()
            compose.onNodeWithTag("home-hosts").performClick()
            compose.onNodeWithTag("group-tree-leaf").assertDoesNotExist()
            compose.onNode(hasSetTextAction()).performTextInput("Database")
            dismissKeyboard()
            compose.onNodeWithTag("group-tree-root").assertExists()
            compose.onNodeWithTag("group-tree-leaf").assertExists()
            compose.onNodeWithTag("host-tree-host").assertExists()
            compose.onNodeWithTag("host-loose-host").assertDoesNotExist()
            compose.onNode(hasSetTextAction()).performTextClearance()
            dismissKeyboard()
            compose.onNodeWithTag("group-tree-leaf").assertDoesNotExist()
            compose.onNodeWithText("全部展开").performClick()
            compose.onNodeWithTag("group-tree-leaf").assertExists()
            compose.onNodeWithTag("host-tree-host").assertIsDisplayed()
            for(theme in listOf("dark","light")){
                compose.runOnIdle{model.theme=theme};compose.waitForIdle()
                InstrumentationRegistry.getInstrumentation().uiAutomation.waitForIdle(200,3000)
                val bitmap=InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                File(compose.activity.cacheDir,"host-tree-$theme.png").outputStream().use{bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)};bitmap.recycle()
            }
            compose.onNodeWithText("全部收起").performClick()
            compose.onNodeWithTag("group-tree-root").assertExists()
            compose.onNodeWithTag("group-tree-child").assertDoesNotExist()
            assertTrue(preferences.getStringSet("collapsedHostGroups",emptySet())!!.contains("tree-root"))
        } finally {
            preferences.edit().putStringSet("collapsedHostGroups",saved).commit()
        }
    }
    private fun dismissKeyboard(){
        compose.runOnIdle{
            val activity=compose.activity
            val keyboard=activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
            keyboard.hideSoftInputFromWindow(activity.window.decorView.windowToken,0)
            activity.currentFocus?.clearFocus()
        }
        compose.waitUntil(5000){compose.activity.window.decorView.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime())!=true}
        compose.waitForIdle()
    }
}
