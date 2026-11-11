package com.termpilot.app

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID

class RemoteConnectionTests {
    @Test fun pinnedRDPReceivesDesktopFrame(){
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val fixture=File(context.cacheDir,"mobile-remote-fixture.json")
        assumeTrue("No authorized pinned RDP fixture",fixture.exists())
        val root=File(context.cacheDir,"rdp-test-${UUID.randomUUID()}").apply{mkdirs()}
        val handle=NativeBridge.create(root.path,ByteArray(32){71})
        try {
            val command=JSONObject(fixture.readText()).getJSONObject("rdp").put("cacheDirectory",File(root,"files").path)
            assertEquals(64,command.getString("certificateSHA256").length)
            val reply=JSONObject(NativeBridge.call(handle,obj("method" to "session.open","protocol" to "rdp","command" to command).toString()))
            assertTrue(reply.optBoolean("ok"))
            val deadline=System.nanoTime()+45_000_000_000L
            var bytes=0
            while(System.nanoTime()<deadline){
                val packet=NativeBridge.poll(handle,100)?:continue
                val n=ByteBuffer.wrap(packet).int;val e=JSONObject(String(packet,4,n,Charsets.UTF_8));val kind=e.optString("kind",e.optString("type"))
                check(kind !in listOf("error","certificate","sessionEnded")){"RDP stopped at $kind: ${e.optString("code")}"}
                if(kind=="frame"){assertEquals("bgrx",e.optString("pixelFormat"));bytes=packet.size-4-n;assertTrue(bytes>=e.getInt("width")*e.getInt("height")*4);break}
            }
            assertTrue("RDP frame must arrive",bytes>0)
            println("Pinned RDP desktop frame received: $bytes bytes")
        }finally{NativeBridge.destroy(handle);root.deleteRecursively();fixture.delete()}
    }
}
