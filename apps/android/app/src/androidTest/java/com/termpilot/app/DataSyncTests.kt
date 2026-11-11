package com.termpilot.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class DataSyncTests {
    @Test fun qrFrameAndInvalidInviteThroughJNI() {
        val root=File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"invite-${UUID.randomUUID()}")
        val handle=NativeBridge.create(root.path,ByteArray(32){17})
        try {
            val result=call(handle,obj("method" to "sync.qr.decode","width" to 640,"height" to 480,"pixels" to android.util.Base64.encodeToString(ByteArray(640*480){-1},android.util.Base64.NO_WRAP)))
            assertTrue(result.isNull("code"))
            val bad=JSONObject(NativeBridge.call(handle,obj("method" to "sync.invite.preview","passphrase" to "bridge-test-key-123","code" to "TP-SYNC:2:unsupported").toString()))
            assertFalse(bad.getBoolean("ok"))
            assertEquals(0,call(handle,obj("method" to "sync.status")).getJSONArray("profiles").length())
        } finally {NativeBridge.destroy(handle);root.deleteRecursively()}
    }

    private fun call(handle:Long,request:JSONObject):JSONObject {
        val response=JSONObject(NativeBridge.call(handle,request.toString()))
        assertTrue(response.toString(),response.getBoolean("ok"))
        return response.getJSONObject("value")
    }
    @Test fun encryptedQRInviteImportsHostsAndCredentialsWithoutLosingLocalRecords() {
        val root=File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"sync-invite-${UUID.randomUUID()}")
        val a=NativeBridge.create(File(root,"A").path,ByteArray(32){31})
        var b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
        val c=NativeBridge.create(File(root,"C").path,ByteArray(32){23})
        try{SyncWebDAVFixture().use{server->
            val key="android-invite-fixture-key"
            fun host(label:String)=obj("label" to label,"hostname" to "fixture.invalid","port" to 22,"username" to "test","connectionKind" to "ssh","authentication" to "password")
            call(a,obj("method" to "vault.save","collection" to "hosts","item" to host("云端主机")))
            call(b,obj("method" to "vault.save","collection" to "hosts","item" to host("本机主机")))
            call(a,obj("method" to "vault.save","collection" to "credentials","item" to obj("label" to "云端凭证","username" to "test","kind" to "identityKey","privateKey" to "fixture-key","savesPassphrase" to true,"passphrase" to "fixture-passphrase")))
            val profile=call(a,obj("method" to "sync.profile.add","title" to "扫码同步测试","provider" to obj("kind" to "webdav","endpoint" to server.endpoint,"username" to "test","password" to "fixture-cloud-password"),"passphrase" to key,"scopes" to JSONArray(listOf("configuration","credentials")),"confirmed" to true)).getJSONArray("profiles").getJSONObject(0).getString("id")
            call(a,obj("method" to "sync.profile.use","id" to profile,"confirmed" to true));call(a,obj("method" to "sync.run"))
            val exported=call(a,obj("method" to "sync.invite.export","id" to profile,"passphrase" to key))
            val code=exported.getString("code")
            val qr=exported.getJSONObject("qr");val modules=qr.getString("modules");val side=qr.getInt("width");val pixels=(side+8)*3
            var frame=ByteArray(pixels*pixels){index->
                val x=index%pixels/3-4;val y=index/pixels/3-4
                if(x in 0 until side&&y in 0 until side&&modules[y*side+x]=='1')0 else (-1).toByte()
            }
            // Camera callbacks retain the sensor orientation. All four rotations must decode.
            repeat(4){
                val decoded=call(b,obj("method" to "sync.qr.decode","width" to pixels,"height" to pixels,"pixels" to android.util.Base64.encodeToString(frame,android.util.Base64.NO_WRAP)))
                assertEquals(code,decoded.getString("code"))
                val previous=frame;frame=ByteArray(previous.size){index->previous[(pixels-1-index%pixels)*pixels+index/pixels]}
            }
            val preview=call(b,obj("method" to "sync.invite.preview","code" to code,"passphrase" to key))
            assertEquals("扫码同步测试",preview.getString("title"))
            assertFalse(preview.getJSONObject("provider").has("password"))
            fun import(runtime:Long,scopes:List<String>)=call(runtime,obj("method" to "sync.invite.import","code" to code,"passphrase" to key,"name" to "Android","scopes" to JSONArray(scopes),"confirmed" to true))
            assertTrue(import(b,listOf("configuration","credentials")).getBoolean("synced"))
            assertEquals(setOf("云端主机","本机主机"),call(b,obj("method" to "vault.list","collection" to "hosts")).objects("items").map{it.getString("label")}.toSet())
            val credential=call(b,obj("method" to "vault.list","collection" to "credentials")).getJSONArray("items").getJSONObject(0)
            assertTrue(credential.getBoolean("savesPassphrase"));assertEquals("fixture-key",credential.getString("privateKey"))
            assertTrue(import(c,listOf("configuration")).getBoolean("synced"))
            assertEquals(2,call(c,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
            assertTrue(call(c,obj("method" to "vault.list","collection" to "credentials")).getJSONArray("items").getJSONObject(0).isNull("privateKey"))
            call(c,obj("method" to "sync.configure","scopes" to JSONArray(listOf("configuration","credentials")),"passphrase" to key,"confirmed" to true))
            call(c,obj("method" to "sync.run"))
            assertEquals(0,call(c,obj("method" to "sync.status")).getJSONArray("conflicts").length())
            NativeBridge.destroy(b);b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
            assertEquals(2,call(b,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
            assertTrue(import(b,listOf("configuration","credentials")).getBoolean("reused"))
            assertEquals(1,call(b,obj("method" to "sync.status")).getJSONArray("profiles").length())
        }}finally{NativeBridge.destroy(a);NativeBridge.destroy(b);NativeBridge.destroy(c);root.deleteRecursively()}
    }
    @Test fun credentialsDoNotRollBackImportedHostsAndSurviveReopening() {
        val root=File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir,"sync-credentials-${UUID.randomUUID()}")
        val a=NativeBridge.create(File(root,"A").path,ByteArray(32){31})
        var b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
        try {
            val library=UUID.randomUUID().toString()
            val provider=obj("kind" to "folder","path" to File(root,"cloud").path)
            for(runtime in listOf(a,b))call(runtime,obj("method" to "sync.configure","provider" to provider,"library" to library,"passphrase" to "android-credential-fixture","scopes" to JSONArray(listOf("configuration","credentials")),"confirmed" to true))
            val credentialID=UUID.randomUUID().toString()
            call(a,obj("method" to "vault.save","collection" to "credentials","item" to obj("id" to credentialID,"label" to "同步密钥","username" to "test","kind" to "identityKey","privateKey" to "fixture-private-key","savesPassphrase" to true,"passphrase" to "fixture-passphrase")))
            repeat(3){index->call(a,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "云端主机-$index","hostname" to "fixture-$index.invalid","port" to 22,"connectionKind" to "ssh","authentication" to "identityFile","username" to "test","credentialID" to credentialID)))}
            call(a,obj("method" to "sync.run"));call(b,obj("method" to "sync.run"))
            assertEquals(3,call(b,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
            val credential=call(b,obj("method" to "vault.get","collection" to "credentials","id" to credentialID)).getJSONObject("item")
            assertTrue(credential.getBoolean("savesPassphrase"))
            assertEquals("fixture-passphrase",credential.getString("passphrase"))
            assertEquals("fixture-private-key",credential.getString("privateKey"))
            fun resolveImportedHosts(){
                val hosts=call(b,obj("method" to "vault.list","collection" to "hosts")).objects("items")
                val credentials=call(b,obj("method" to "vault.list","collection" to "credentials")).getJSONArray("items")
                for(host in hosts){
                    val resolved=call(b,obj("method" to "resolveConnection","host" to host,"credentials" to credentials,"proxyProfiles" to JSONArray())).getJSONObject("host")
                    assertEquals("identityFile",resolved.getString("authentication"))
                    assertEquals("fixture-private-key",resolved.getString("identityKey"))
                    assertEquals("fixture-passphrase",resolved.getString("passphrase"))
                }
            }
            resolveImportedHosts()
            NativeBridge.destroy(b);b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
            assertEquals(3,call(b,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
            resolveImportedHosts()
            call(b,obj("method" to "sync.run"));call(a,obj("method" to "sync.run"))
            for(runtime in listOf(a,b))assertEquals(0,call(runtime,obj("method" to "sync.status")).getJSONArray("conflicts").length())
        }finally{NativeBridge.destroy(a);NativeBridge.destroy(b);root.deleteRecursively()}
    }
    @Test fun offlineReplicasUseDifferentDeviceKeysAndMergeThroughEncryptedObjects() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val root=File(context.cacheDir,"sync-${UUID.randomUUID()}").apply{mkdirs()}
        val a=NativeBridge.create(File(root,"A").path,ByteArray(32){31})
        val b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
        assertNotEquals(0L,a);assertNotEquals(0L,b)
        try {
            val library=UUID.randomUUID().toString()
            listOf(a,b).forEachIndexed { index,runtime ->
                call(runtime,obj("method" to "sync.configure","provider" to obj("kind" to "folder","path" to File(root,"cloud").path),"library" to library,"passphrase" to "android-sync-fixture-only","scopes" to JSONArray(listOf("configuration","preferences")),"confirmed" to true))
                assertTrue(call(runtime,obj("method" to "sync.tick")).getBoolean("skipped"))
                call(runtime,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "Android-$index","hostname" to "fixture.invalid","port" to 22,"connectionKind" to "ssh","username" to "test","authentication" to "password","password" to "fixture-not-published")))
            }
            call(a,obj("method" to "sync.preferences","values" to obj("theme" to "light")))
            call(a,obj("method" to "sync.run"));call(b,obj("method" to "sync.run"))
            assertEquals("light",call(a,obj("method" to "sync.run")).getJSONObject("preferences").getString("theme"))
            listOf(a,b).forEach { assertEquals(2,call(it,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length()) }
            assertFalse(File(root,"A/credential.key").exists())
            File(root,"cloud").listFiles()!!.forEach { assertFalse(it.readBytes().toString(Charsets.ISO_8859_1).contains("fixture-not-published")) }
        } finally {NativeBridge.destroy(a);NativeBridge.destroy(b);root.deleteRecursively()}
    }
    @Test fun passwordChangeKeepsOfflineChangesAcrossDeviceKeys() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val root=File(context.cacheDir,"rekey-${UUID.randomUUID()}").apply{mkdirs()}
        val a=NativeBridge.create(File(root,"A").path,ByteArray(32){31})
        val b=NativeBridge.create(File(root,"B").path,ByteArray(32){72})
        try {
            val library=UUID.randomUUID().toString()
            for(runtime in listOf(a,b)) {
                call(runtime,obj("method" to "sync.configure","provider" to obj("kind" to "folder","path" to File(root,"cloud").path),"library" to library,"passphrase" to "original-test-passphrase","confirmed" to true))
                call(runtime,obj("method" to "sync.run"))
            }
            call(b,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "offline-rekey","hostname" to "fixture.invalid","port" to 22,"connectionKind" to "ssh","username" to "test","authentication" to "password")))
            call(a,obj("method" to "sync.password.begin","oldPassphrase" to "original-test-passphrase","newPassphrase" to "replacement-test-passphrase","confirmPassphrase" to "replacement-test-passphrase","confirmed" to true,"clientsUpdated" to true))
            assertEquals("completed",call(a,obj("method" to "sync.password.resume")).getJSONObject("passwordChange").getString("phase"))
            call(b,obj("method" to "sync.password.unlock","passphrase" to "replacement-test-passphrase"))
            call(b,obj("method" to "sync.run"));call(a,obj("method" to "sync.run"))
            assertEquals(1,call(a,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
        } finally {NativeBridge.destroy(a);NativeBridge.destroy(b);root.deleteRecursively()}
    }

    @Test fun namedProfilesSwitchWithoutLosingLocalData() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val root=File(context.cacheDir,"profiles-${UUID.randomUUID()}").apply{mkdirs()}
        val runtime=NativeBridge.create(File(root,"local").path,ByteArray(32){31})
        try {
            var profiles=JSONArray()
            for(title in listOf("Home","Office")) {
                profiles=call(runtime,obj("method" to "sync.profile.add","title" to title,"provider" to obj("kind" to "folder","path" to File(root,title).path),"name" to "Android","passphrase" to "android-profile-password","scopes" to JSONArray().put("configuration"),"confirmed" to true)).getJSONArray("profiles")
            }
            assertEquals(2,profiles.length())
            val a=profiles.getJSONObject(0).getString("id");val b=profiles.getJSONObject(1).getString("id")
            call(runtime,obj("method" to "sync.profile.use","id" to a,"confirmed" to true))
            call(runtime,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "profile-host","hostname" to "fixture.invalid","port" to 22,"connectionKind" to "ssh","username" to "test","authentication" to "password")))
            call(runtime,obj("method" to "sync.profile.use","id" to b,"confirmed" to true));call(runtime,obj("method" to "sync.run"))
            call(runtime,obj("method" to "sync.profile.use","id" to a,"confirmed" to true))
            assertEquals(a,call(runtime,obj("method" to "sync.run")).getString("activeProfile"))
            assertEquals(1,call(runtime,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
        } finally {NativeBridge.destroy(runtime);root.deleteRecursively()}
    }

}
