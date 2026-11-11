package com.termpilot.app

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class HostKeyPersistenceTests {
    // Exercise the retained JNI API directly, without coupling this protocol
    // regression to the application UI helpers.
    private fun obj(vararg entries: Pair<String, Any>): JSONObject = JSONObject().apply {
        entries.forEach { (name, value) -> put(name, value) }
    }
    @Test fun firstApprovalPersistsAndReconnectDoesNotPrompt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val fixture = File(context.cacheDir, "mobile-fixture.json")
        assumeTrue("No authorized live-host fixture", fixture.exists())
        val source = JSONObject(fixture.readText())
        val root = File(context.cacheDir, "host-key-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            val saved = LiveTestFixture.host(source, "tools")
            val host = saved.getString("hostname")
            val port = saved.optInt("port", 22)
            val pattern = if (port == 22) host else "[$host]:$port"
            // These are existing, independently approved desktop pins, not fetched from the connection.
            val keys = source.getJSONObject("verifiedHostKeys").getJSONArray(pattern)
            val approved = (0 until keys.length()).map { keys.getString(it) }.associateBy {
                "SHA256:" + Base64.encodeToString(MessageDigest.getInstance("SHA-256")
                    .digest(Base64.decode(it, Base64.DEFAULT)), Base64.NO_WRAP or Base64.NO_PADDING)
            }
            assertTrue("Missing approved host key", approved.isNotEmpty())
            val known = File(root, "known_hosts")
            assertFalse(known.exists())
            repeat(2) { attempt ->
                val handle = NativeBridge.create(root.path, ByteArray(32) { 77 })
                assertNotEquals(0L, handle)
                try {
                    fun call(request: JSONObject): JSONObject {
                        val response = JSONObject(NativeBridge.call(handle, request.toString()))
                        check(response.optBoolean("ok")) { "Host-key test request failed" }
                        return response.getJSONObject("value")
                    }
                    val config = JSONObject(saved.toString()).put("knownHostsFile", known.path)
                        .put("autoAcceptHostKeys", false)
                    val session = call(obj("method" to "session.open", "protocol" to "ssh",
                        "command" to obj("type" to "connect", "config" to config, "cols" to 80, "rows" to 24)))
                        .getLong("session")
                    fun send(command: JSONObject) { call(obj("method" to "session.send", "session" to session, "command" to command)) }
                    var prompts = 0
                    fun waitFor(predicate: (JSONObject) -> Boolean) {
                        val deadline = System.nanoTime() + 60_000_000_000L
                        while (System.nanoTime() < deadline) {
                            val bytes = NativeBridge.poll(handle, 100) ?: continue
                            val count = ByteBuffer.wrap(bytes).int
                            val event = JSONObject(String(bytes, 4, count, Charsets.UTF_8))
                            if (event.optLong("session") != session) continue
                            if (event.optString("type") == "hostKeyPrompt") {
                                assertEquals("Reconnection must use persisted pin", 0, attempt)
                                val detail = event.getJSONObject("detail")
                                assertEquals(pattern, detail.getString("hostPattern"))
                                assertTrue("Unapproved host key", approved.containsKey(detail.getString("fingerprint")))
                                assertFalse(detail.getBoolean("hasHostPattern"))
                                prompts++
                                send(obj("type" to "hostKeyResponse", "promptID" to event.getString("promptID"), "accepted" to true))
                            }
                            check(event.optString("type") !in listOf("error", "sessionEnded", "credentialPrompt")) {
                                "SSH first-use/reconnect failed: ${event.optString("message")}"
                            }
                            if (predicate(event)) return
                        }
                        error("Host-key test timed out")
                    }
                    waitFor { it.optString("type") == "log" && it.optString("status") == "connected" }
                    assertEquals(if (attempt == 0) 1 else 0, prompts)
                    assertTrue("Accepted key must be persisted", known.isFile && approved.values.any { known.readText().contains(it) })
                    send(obj("type" to "sftpOpen", "config" to obj("fileProtocol" to "sftp")))
                    waitFor { it.optString("type") == "sftpReady" }
                    call(obj("method" to "session.close", "session" to session))
                } finally { NativeBridge.destroy(handle) }
            }
            println("Android first SSH approval, known_hosts persistence, runtime reopen and SFTP passed")
        } finally { fixture.delete(); root.deleteRecursively() }
    }
}
