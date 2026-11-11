package com.termpilot.app

import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

class SyncedConnectionTests {
    @Test fun syncedHostAndCredentialCanAuthenticateAndExecuteOverSSH(){
        val cache=InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        // Supplied by an isolated loopback sshd with an ephemeral client/host key.
        val fixture=File(cache,"connection-fixture.json")
        assumeTrue("No local SSH test fixture",fixture.exists())
        val settings=JSONObject(fixture.readText())
        val root=File(cache,"sync-connect-${UUID.randomUUID()}")
        val a=NativeBridge.create(File(root,"A").path,ByteArray(32){51})
        val b=NativeBridge.create(File(root,"B").path,ByteArray(32){82})
        fun call(handle:Long,request:JSONObject):JSONObject {
            val result=JSONObject(NativeBridge.call(handle,request.toString()))
            check(result.optBoolean("ok")){result.optJSONObject("error")?.optString("message")?:"Native request failed"}
            return result.getJSONObject("value")
        }
        try {
            val library=UUID.randomUUID().toString()
            for(h in listOf(a,b))call(h,obj("method" to "sync.configure","provider" to obj("kind" to "folder","path" to File(root,"cloud").path),"library" to library,"passphrase" to "local-connection-test-key","scopes" to JSONArray(listOf("configuration","credentials")),"confirmed" to true))
            val credentialID=UUID.randomUUID().toString()
            call(a,obj("method" to "vault.save","collection" to "credentials","item" to obj("id" to credentialID,"label" to "Loopback test key","kind" to "identityKey","username" to settings.getString("username"),"privateKey" to settings.getString("privateKey"),"savesPassphrase" to false)))
            call(a,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "Synced SSH fixture","hostname" to settings.getString("host"),"port" to settings.getInt("port"),"username" to settings.getString("username"),"connectionKind" to "ssh","authentication" to "identityFile","credentialID" to credentialID)))
            call(a,obj("method" to "sync.run"));call(b,obj("method" to "sync.run"))
            val saved=call(b,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").getJSONObject(0)
            val credentials=call(b,obj("method" to "vault.list","collection" to "credentials")).getJSONArray("items")
            val host=call(b,obj("method" to "resolveConnection","host" to saved,"credentials" to credentials,"proxyProfiles" to JSONArray())).getJSONObject("host")
            val known=File(root,"known_hosts").apply{writeText(settings.getString("knownHosts"))}
            host.put("host",host.getString("hostname")).put("privateKey",host.getString("identityKey")).put("knownHostsFile",known.path)
            val session=call(b,obj("method" to "session.open","protocol" to "ssh","terminalReplies" to true,"command" to obj("type" to "connect","config" to host,"cols" to 80,"rows" to 24))).getLong("session")
            fun awaitEvent(predicate:(JSONObject)->Boolean){
                val deadline=System.nanoTime()+30_000_000_000L
                while(System.nanoTime()<deadline){
                    val packet=NativeBridge.poll(b,100)?:continue
                    val e=decodeMobilePacket(packet).header
                    if(e.optLong("session")!=session)continue
                    check(e.optString("type") !in listOf("error","hostKeyPrompt","credentialPrompt","sessionEnded")){"SSH stopped: ${e.optString("type")} ${e.optString("message")}"}
                    if(predicate(e))return
                }
                error("Timed out waiting for local SSH fixture")
            }
            awaitEvent{it.optString("type")=="log"&&it.optString("status")=="connected"}
            val command="printf 'TermPilot-%s\\n' 'synced-login-ok'\r"
            call(b,obj("method" to "session.send","session" to session,"command" to obj("type" to "data","data" to Base64.encodeToString(command.toByteArray(),Base64.NO_WRAP))))
            var output=""
            awaitEvent{
                if(it.optString("type")=="data")output=(output+Base64.decode(it.getString("data"),Base64.DEFAULT).toString(Charsets.UTF_8)).takeLast(65536)
                output.contains("TermPilot-synced-login-ok")
            }
            call(b,obj("method" to "session.close","session" to session))
            assertEquals(1,call(b,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
        } finally {NativeBridge.destroy(a);NativeBridge.destroy(b);root.deleteRecursively();fixture.delete()}
    }
}
