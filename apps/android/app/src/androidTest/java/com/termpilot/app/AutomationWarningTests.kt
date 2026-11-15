package com.termpilot.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AutomationWarningTests {
    @Test fun warningStaysWithItsSessionWithoutDisconnectingOrChangingConversation() {
        val a=Session(42,obj("id" to "fixture-a"),"ssh","fixture")
        val b=Session(43,obj("id" to "fixture-b"),"ssh","other")
        a.connected=true
        a.conversation=obj("id" to "chat-a","status" to "running")
        val event=obj("type" to "automationError","sessionId" to "42","message" to "Fixture queue failure")
        a.receiveAutomationWarning(event)
        b.receiveAutomationWarning(event)
        assertEquals("Fixture queue failure",a.automationWarning)
        assertNull(b.automationWarning)
        assertTrue(a.connected)
        assertEquals("running",a.conversation.getString("status"))
        assertEquals("chat-a",a.conversation.getString("id"))
        a.automationWarning=null
        assertNull(a.automationWarning)
    }
}
