package com.termpilot.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class SyncLeaseSettingsTests {
    @get:Rule val compose=createComposeRule()
    @Test fun timeoutUsesMinutesRejectsInvalidValuesAndSaves() {
        var saved=60
        compose.setContent {
            var minutes by remember { mutableStateOf(60) }
            MaterialTheme { SyncLeaseSettings(minutes,true) { saved=it;minutes=it } }
        }
        compose.onNodeWithTag("sync-lock-timeout-save").assertIsNotEnabled()
        for (value in listOf("0","1441","1.5","")) {
            compose.onNodeWithTag("sync-lock-timeout").performTextReplacement(value)
            compose.onNodeWithTag("sync-lock-timeout-save").assertIsNotEnabled()
        }
        compose.onNodeWithTag("sync-lock-timeout").performTextReplacement("17")
        compose.onNodeWithTag("sync-lock-timeout-save").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(17,saved) }
        compose.onNodeWithTag("sync-lock-timeout-save").assertIsNotEnabled()
        compose.onNodeWithTag("sync-lock-timeout").assertTextContains("17")
    }
}
