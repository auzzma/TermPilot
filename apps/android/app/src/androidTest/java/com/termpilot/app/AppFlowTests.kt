package com.termpilot.app

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Exercises the same model/background/history path used by the visible native UI. */
@RunWith(AndroidJUnit4::class)
class AppFlowTests {
 @Test fun nativeModelConnectsTransfersAndRecordsHistory(){
  val context=InstrumentationRegistry.getInstrumentation().targetContext
  val fixture=File(context.cacheDir,"mobile-fixture.json")
  assumeTrue("No authorized fixture",fixture.exists())
  val source=JSONObject(fixture.readText())
  val host=LiveTestFixture.host(source, "ssh")
  ActivityScenario.launch(MainActivity::class.java).use{scenario->
   val result=CompletableFuture<Unit>()
   scenario.onActivity{activity->CoroutineScope(Dispatchers.Main).launch{
    val model=activity.mobileModel;var session:Session?=null;var remote="";var original:ByteArray?=null;var known:File?=null;var failure:Throwable?=null
    try {
     withTimeout(15000){while(!model.ready)delay(30)}
     known=File(model.runtime!!.directory,"known_hosts");original=known.takeIf{it.exists()}?.readBytes();known.writeText(source.getString("knownHosts"))
     assertNotNull(model.openAISettings().ai)
     model.connect(JSONObject(host.toString()).put("label","移动原生界面验收").put("connectionKind","ssh"))
     val s=checkNotNull(model.current);session=s
     withTimeout(30000){while(!s.filesReady||!s.execReady)delay(30)}
     model.openAI(s);assertTrue(s.conversation.optString("id").isNotEmpty())
     assertEquals(s.aiScope,s.conversation.optString("scope"))
     val root=File(model.runtime!!.directory,"Transfers/ui-test-${UUID.randomUUID()}").apply{mkdirs()}
     try {
      val input=File(root,"native-中文.bin");withContext(Dispatchers.IO){input.outputStream().use{out->val b=ByteArray(1024*1024){it.toByte()};repeat(64){out.write(b)}}}
      remote=model.files(s,obj("action" to "realpath","path" to ".")).getString("path")+"/TermPilot-native-${UUID.randomUUID()}.bin"
      val upload=async{model.transfer(s,true,input,remote)}
      withTimeout(10000){while(s.transfers.values.firstOrNull()?.optLong("transferred",0)==null||s.transfers.values.firstOrNull()?.optLong("transferred",0)==0L)delay(10)}
      val transferID=s.transfers.keys.first()
      model.controlTransfer(s,transferID,"pause")
      assertTrue(model.transferHistory.any{it.optString("id")==transferID&&it.optString("status")=="paused"})
      model.controlTransfer(s,transferID,"resume")
      upload.await()
      assertTrue(model.transferHistory.any{it.optString("name")==input.name&&it.optString("status")=="completed"})
      assertTrue(model.backgroundTransfers.isEmpty())
      assertTrue(model.records["history"]!!.any{it.optString("id")==s.host.optString("sessionID")&&it.optBoolean("succeeded")})
      val tools=model.exec(s,"command -v tmux; command -v docker; printf 'TermPilot native model verified\\n'")
      assertTrue(tools.optString("stdout").contains("TermPilot native model verified"))
     }finally{root.deleteRecursively()}
    }catch(e:Throwable){failure=e}finally{
     session?.let{s->if(remote.isNotEmpty())runCatching{model.files(s,obj("action" to "delete","path" to remote))};runCatching{model.close(s)}}
     if(original!=null)known?.writeBytes(original!!)else known?.delete()
     fixture.delete();if(failure==null)result.complete(Unit)else result.completeExceptionally(failure!!)
    }
   }}
   result.get(150,TimeUnit.SECONDS)
  }
 }
}
