package com.termpilot.app
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import java.io.File
import java.nio.ByteBuffer
import java.util.UUID
class ScreenConnectionTests {
 @Test fun vncAndAppleHighPerformanceReceiveFrames(){
  val context=InstrumentationRegistry.getInstrumentation().targetContext;val fixture=File(context.cacheDir,"mobile-screen-fixture.json")
  assumeTrue("No authorized screen fixture",fixture.exists())
  try {val source=JSONObject(fixture.readText())
   for((mode,codec) in listOf("standardVNC" to "h264","highPerformance" to "h264","highPerformance" to "h265")){
    val root=File(context.cacheDir,"screen-test-${UUID.randomUUID()}").apply{mkdirs()};val h=NativeBridge.create(root.path,ByteArray(32){43})
    try {val c=JSONObject(source.getJSONObject("screen").toString()).put("mode",mode).put("videoCodec",codec).put("lockDirectory",File(root,"lock").path)
     val response=JSONObject(NativeBridge.call(h,obj("method" to "session.open","protocol" to "screen","command" to c).toString()));assertTrue(response.optBoolean("ok"))
     var diagnostic="";val seen=mutableSetOf<Int>();val expected=if(mode=="highPerformance"&&codec=="h265")4 else 1;val deadline=System.nanoTime()+60_000_000_000
     while(System.nanoTime()<deadline&&seen.size<expected){val p=NativeBridge.poll(h,100)?:continue;val n=ByteBuffer.wrap(p).int;val e=JSONObject(String(p,4,n,Charsets.UTF_8));val kind=e.optString("kind",e.optString("type"))
      check(kind !in listOf("error","disconnected","sessionEnded")){"Screen stopped: ${e.optString("code",e.optString("error",kind))}"}
      if(kind in listOf("status","mediaDiagnostics","performance"))diagnostic=e.toString()
      if(kind=="frame"){assertTrue(p.size>4+n);seen.add(e.optInt("tile"))}
     };assertEquals("Final media status: $diagnostic",expected,seen.size);println("Mobile screen result: $mode / $codec tiles=${seen.size}")
    }finally{NativeBridge.destroy(h);Thread.sleep(2000);root.deleteRecursively()}
   }
  }finally{fixture.delete()}
 }
}
