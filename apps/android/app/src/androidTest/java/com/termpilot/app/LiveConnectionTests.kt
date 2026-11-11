package com.termpilot.app

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
class LiveConnectionTests {
    @Test fun sshAndSFTPRoundTripOnAuthorizedHosts() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val fixture=File(context.cacheDir,"mobile-fixture.json")
        assumeTrue("No authorized live-host fixture",fixture.exists())
        val source=JSONObject(fixture.readText())
        try { source.objects("hosts").forEach { saved ->
            val root=File(context.cacheDir,"mobile-live-${UUID.randomUUID()}").apply{mkdirs()}
            val handle=NativeBridge.create(root.path,ByteArray(32){77})
            assertNotEquals(0L,handle)
            fun call(request:JSONObject):JSONObject {
                val result=JSONObject(NativeBridge.call(handle,request.toString()))
                check(result.optBoolean("ok")){"Native live-test request failed"}
                return result.getJSONObject("value")
            }
            try {
                val known=File(root,"known_hosts").apply{writeText(source.getString("knownHosts"))}
                val config=JSONObject(saved.toString()).put("knownHostsFile",known.path)
                val opened=call(obj("method" to "session.open","protocol" to "ssh","terminalReplies" to true,"command" to obj("type" to "connect","config" to config,"cols" to 80,"rows" to 24)))
                val session=opened.getLong("session")
                fun send(command:JSONObject){call(obj("method" to "session.send","session" to session,"command" to command))}
                fun waitFor(predicate:(JSONObject)->Boolean):JSONObject {
                    val until=System.nanoTime()+300_000_000_000L
                    while(System.nanoTime()<until){
                        val bytes=NativeBridge.poll(handle,100)?:continue
                        val n=ByteBuffer.wrap(bytes).int
                        val e=JSONObject(String(bytes,4,n,Charsets.UTF_8))
                        check(e.optString("type") !in listOf("hostKeyPrompt","credentialPrompt","sessionEnded","error")){"Live SSH stopped at ${e.optString("type")}: ${e.optString("message")}"}
                        if(predicate(e))return e
                    }
                    error("Live SSH event timed out")
                }
                waitFor{it.optString("type")=="log"&&it.optString("status")=="connected"}
                send(obj("type" to "sftpOpen","config" to obj("fileProtocol" to "sftp")))
                waitFor{it.optString("type")=="sftpReady"}
                fun files(request:JSONObject):JSONObject {
                    val id=UUID.randomUUID().toString();request.put("id",id)
                    send(obj("type" to "sftpRequest","channel" to "files","request" to request))
                    val e=waitFor{it.optString("type")=="sftpResponse"&&it.optJSONObject("message")?.optString("id")==id&&it.getJSONObject("message").has("ok")}.getJSONObject("message")
                    check(e.optBoolean("ok")){"Live SFTP ${request.optString("action")} failed: ${e.optString("error")}"}
                    return e.optJSONObject("result")?:JSONObject()
                }
                val home=files(obj("action" to "realpath","path" to ".")).getString("path")
                val folder="$home/TermPilot-mobile-test-${UUID.randomUUID()}"
                files(obj("action" to "mkdir","path" to folder))
                try {
                    val data=ByteArray(1024*1024){(it*31).toByte()};val blocks=if(saved.optString("hostname")==LiveTestFixture.hostname(source, "largeTransfer"))200 else 2
                    val input=File(root,"upload-中文.bin").apply{outputStream().use{out->repeat(blocks){out.write(data)}}}
                    val output=File(root,"download-中文.bin")
                    files(obj("action" to "upload","localPath" to input.path,"remotePath" to "$folder/中文.bin","overwrite" to false,"resumeDirectory" to File(root,"checkpoints").path))
                    files(obj("action" to "rename","oldPath" to "$folder/中文.bin","newPath" to "$folder/renamed.bin"))
                    files(obj("action" to "download","localPath" to output.path,"remotePath" to "$folder/renamed.bin","overwrite" to false,"resumeDirectory" to File(root,"download-checkpoints").path))
                    fun digest(file:File):ByteArray {val h=MessageDigest.getInstance("SHA-256");file.inputStream().use{input->val b=ByteArray(1024*1024);while(true){val n=input.read(b);if(n<0)break;h.update(b,0,n)}};return h.digest()}
                    assertArrayEquals(digest(input),digest(output))
                    println("Mobile SSH/SFTP ${blocks} MiB SHA-256 roundtrip passed: ${saved.getString("hostname")}")
                } finally { files(obj("action" to "delete","path" to folder)) }
                call(obj("method" to "session.close","session" to session))
            } finally { NativeBridge.destroy(handle);root.deleteRecursively() }
        } } finally { fixture.delete() }
    }
}
