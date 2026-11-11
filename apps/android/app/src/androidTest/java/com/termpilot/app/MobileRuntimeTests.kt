package com.termpilot.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import android.content.ContextWrapper
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class MobileRuntimeTests {
    @Test fun duplicateDraftAndSyncProgressAcrossMobileBridge()=runtimeTest{handle,root,_->
        call(handle,obj("method" to "sync.configure","provider" to obj("kind" to "folder","path" to File(root,"cloud").path),"passphrase" to "test-copy-progress-key","confirmed" to true))
        val original=call(handle,obj("method" to "vault.save","collection" to "hosts","item" to obj("label" to "Original","hostname" to "fixture.invalid","port" to 5900,"connectionKind" to "screenSharing","authentication" to "password","username" to "test"),"screenSharingProfile" to obj("mode" to "highPerformance","username" to "test","password" to "fixture-secret","port" to 5900,"audio" to false))).getJSONObject("item")
        val draft=call(handle,obj("method" to "vault.host.duplicateDraft","id" to original.getString("id")))
        assertEquals(1,call(handle,obj("method" to "vault.list","collection" to "hosts")).getJSONArray("items").length())
        val copy=draft.getJSONObject("item").put("label","Edited copy")
        assertNotEquals(original.getString("id"),copy.getString("id"));assertFalse(copy.has("updatedAt"))
        call(handle,obj("method" to "vault.save","collection" to "hosts","item" to copy,"screenSharingProfile" to draft.getJSONObject("screenSharingProfile")))
        call(handle,obj("method" to "sync.run"))
        val progress=call(handle,obj("method" to "sync.progress"))
        assertEquals("completed",progress.getString("phase"));assertEquals(100,progress.getInt("percent"))
        assertTrue(progress.getLong("uploadedBytes")>0);assertEquals(progress.getLong("uploadedBytes"),progress.getLong("verifiedBytes"))
        assertEquals("Original",call(handle,obj("method" to "vault.get","collection" to "hosts","id" to original.getString("id"))).getJSONObject("item").getString("label"))
        val profile=call(handle,obj("method" to "vault.get","collection" to "screenSharing","id" to copy.getString("id"))).getJSONObject("item")
        assertEquals("highPerformance",profile.getString("mode"));assertFalse(profile.getBoolean("audio"))
    }

    @Test fun rapidUICallsKeepInputOrderAcrossBackgroundDispatch()=runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val root=File(context.cacheDir,"input-order-${UUID.randomUUID()}").apply{mkdirs()}
        val isolated=object:ContextWrapper(context){override fun getFilesDir()=root}
        val runtime=MobileRuntime(isolated)
        try {
            val terminal=runtime.call(obj("method" to "terminal.create","rows" to 2,"columns" to 200)).getString("id")
            val expected=(0 until 128).joinToString(""){('!'.code+it%90).toChar().toString()}
            withContext(Dispatchers.Main.immediate) {
                coroutineScope {
                    expected.forEach { char -> launch {
                        runtime.call(obj("method" to "terminal.feed","id" to terminal,
                            "data" to android.util.Base64.encodeToString(char.toString().toByteArray(),android.util.Base64.NO_WRAP)))
                    } }
                }
            }
            val cells=runtime.call(obj("method" to "terminal.snapshot","id" to terminal)).getJSONArray("cells")
            val actual=(0 until expected.length).joinToString(""){cells.getJSONObject(it).getString("text")}
            assertEquals("Keyboard requests must not overtake earlier key events",expected,actual)
            runtime.call(obj("method" to "terminal.close","id" to terminal))
            Unit
        } finally {runtime.close();root.deleteRecursively()}
    }
    private fun runtimeTest(block:(Long,File,ByteArray)->Unit) {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val root=File(context.cacheDir,"runtime-${UUID.randomUUID()}").apply{mkdirs()}
        val key=ByteArray(32){37};val handle=NativeBridge.create(root.path,key)
        assertNotEquals(0L,handle)
        try{block(handle,root,key)}finally{NativeBridge.destroy(handle);root.deleteRecursively()}
    }
    private fun call(handle:Long,request:JSONObject):JSONObject {
        val response=JSONObject(NativeBridge.call(handle,request.toString()))
        assertTrue(response.toString(),response.getBoolean("ok"))
        return response.getJSONObject("value")
    }
    @Test fun connectionPreparationDoesNotRequireCallerAPIVersion()=runtimeTest{h,_,_->
        for(kind in listOf("ssh","rdp","screenSharing")){
            val host=obj("label" to "移动连接测试","hostname" to "fixture.invalid","port" to 22,"username" to "test","connectionKind" to kind,"authentication" to "password","password" to "fixture-password")
            // AppModel.connect sends this envelope for both quick and saved connections.
            for(saved in listOf(false,true)){
                if(saved)host.put("id",UUID.randomUUID().toString())
                val resolved=call(h,obj("method" to "resolveConnection","host" to host,"credentials" to JSONArray(),"proxyProfiles" to JSONArray())).getJSONObject("host")
                assertEquals(kind,resolved.getString("connectionKind"))
                assertEquals("fixture-password",resolved.getString("password"))
            }
        }
        val missing=JSONObject(NativeBridge.call(h,obj("method" to "resolveConnection","host" to obj("hostname" to "fixture.invalid","credentialID" to UUID.randomUUID().toString()),"credentials" to JSONArray()).toString()))
        assertFalse(missing.getBoolean("ok"))
        assertEquals("The selected credential no longer exists.",missing.getJSONObject("error").getString("message"))
        assertTrue(call(h,obj("method" to "info")).getInt("apiVersion")>0)
    }
    @Test fun nativeVaultPersistsEncryptedCredentialWithoutPlaintextKey()=runtimeTest{h,root,key->
        call(h,obj("method" to "vault.save","collection" to "credentials","item" to obj("id" to UUID.randomUUID().toString(),"label" to "测试凭证","kind" to "password","username" to "test","password" to "android-fixture-password")))
        NativeBridge.destroy(h)
        val reopened=NativeBridge.create(root.path,key)
        try{val r=call(reopened,obj("method" to "vault.list","collection" to "credentials"));assertEquals("android-fixture-password",r.getJSONArray("items").getJSONObject(0).getString("password"))}finally{NativeBridge.destroy(reopened)}
        assertFalse(File(root,"credential.key").exists())
        assertFalse(File(root,"vault.sqlite").readBytes().toString(Charsets.ISO_8859_1).contains("android-fixture-password"))
    }
    @Test fun nativeTerminalParsesUnicodeAndReplies()=runtimeTest{h,_,_->
        val terminal=call(h,obj("method" to "terminal.create","rows" to 3,"columns" to 40)).getString("id")
        val bytes=android.util.Base64.encodeToString("中文\r\n\u001b[6n".toByteArray(),android.util.Base64.NO_WRAP)
        val result=call(h,obj("method" to "terminal.feed","id" to terminal,"data" to bytes))
        assertEquals("\u001b[2;1R",android.util.Base64.decode(result.getString("reply"),0).toString(Charsets.UTF_8))
        assertEquals("中",call(h,obj("method" to "terminal.snapshot","id" to terminal)).getJSONArray("cells").getJSONObject(0).getString("text"))
        call(h,obj("method" to "terminal.close","id" to terminal))
    }
    @Test fun keystoreWrapperReopensSameVault()=runBlocking {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val first=MobileRuntime(context)
        val count=first.call(obj("method" to "vault.list","collection" to "hosts")).objects("items").size
        first.close()
        val second=MobileRuntime(context)
        try{assertEquals(count,second.call(obj("method" to "vault.list","collection" to "hosts")).objects("items").size)}finally{second.close()}
    }
}
