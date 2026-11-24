package com.termpilot.app

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class QuickCredentialTests {
    @Test fun independentStrategiesPersistReferencesOnly() {
        val values = mutableMapOf<String,String>()
        val editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java)) { proxy, method, args ->
            when (method.name) {
                "putString" -> { values[args[0] as String] = args[1] as String; proxy }
                "apply" -> null
                else -> error("Unexpected editor method: ${method.name}")
            }
        } as SharedPreferences.Editor
        val storage = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getString" -> values[args[0]] ?: args[1]
                "edit" -> editor
                else -> error("Unexpected preference method: ${method.name}")
            }
        } as SharedPreferences
        val preferences = QuickCredentialPreferences(storage)
        for (protocol in QuickCredentialProtocol.entries) assertEquals(QuickCredentialStrategy.manual, preferences.strategy(protocol))
        preferences.configure(QuickCredentialProtocol.ssh, QuickCredentialStrategy.fixed, "ssh-key")
        preferences.configure(QuickCredentialProtocol.rdp, QuickCredentialStrategy.recent, "")
        preferences.configure(QuickCredentialProtocol.standardVNC, QuickCredentialStrategy.recent, "")
        preferences.configure(QuickCredentialProtocol.highPerformance, QuickCredentialStrategy.fixed, "mac")
        preferences.connected(QuickCredentialProtocol.ssh, "temporary")
        preferences.connected(QuickCredentialProtocol.rdp, "windows")
        preferences.connected(QuickCredentialProtocol.standardVNC, "vnc")
        val reopened = QuickCredentialPreferences(storage)
        assertEquals("ssh-key", reopened.selected(QuickCredentialProtocol.ssh))
        assertEquals("windows", reopened.selected(QuickCredentialProtocol.rdp))
        assertEquals("vnc", reopened.selected(QuickCredentialProtocol.standardVNC))
        assertEquals("mac", reopened.selected(QuickCredentialProtocol.highPerformance))
        for (protocol in QuickCredentialProtocol.entries) {
            assertTrue(protocol.supports("password"))
            assertEquals(protocol == QuickCredentialProtocol.ssh, protocol.supports("identityKey"))
            assertFalse(protocol.supports("unknown"))
        }
        assertTrue(values.keys.all { it.endsWith("strategy") || it.endsWith("fixed") || it.endsWith("recent") })
    }
}
