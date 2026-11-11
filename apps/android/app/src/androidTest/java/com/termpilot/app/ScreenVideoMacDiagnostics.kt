package com.termpilot.app

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Opt-in live test of AppModel -> Compose -> GL pixels; never submits login. */
class ScreenVideoMacDiagnostics {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()

    @Test fun inspectLiveMacSurface() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val fixture=File(context.cacheDir,"mobile-screen-fixture.json")
        assumeTrue(fixture.exists())
        val mode=InstrumentationRegistry.getArguments().getString("screenMode","standardVNC")
        val model=compose.activity.mobileModel
        compose.waitUntil(15000){model.ready}
        val config=JSONObject(fixture.readText()).getJSONObject("screen")
        config.put("id",UUID.randomUUID().toString()).put("hostname",config.getString("host"))
            .put("label","Mac video verification").put("connectionKind","screenSharing").put("mode",mode)
        val command=File(context.cacheDir,"screen-video-command.json")
        val state=File(context.cacheDir,"screen-video-state.json")
        command.delete();state.delete()
        runBlocking { withContext(Dispatchers.Main){model.connect(config)} }
        val session=compose.runOnIdle{model.current!!}
        fun <T:View> find(view:View,type:Class<T>):T? {
            if(type.isInstance(view))return type.cast(view)
            if(view is ViewGroup)for(i in 0 until view.childCount)find(view.getChildAt(i),type)?.let{return it}
            return null
        }
        var done=0
        try {
            val deadline=System.nanoTime()+300_000_000_000L
            while(System.nanoTime()<deadline) {
                var finish=false
                if(command.exists()) {
                    val action=JSONObject(command.readText());command.delete()
                    val op=action.getString("op")
                    if(op=="capture") {
                        lateinit var bitmap:Bitmap
                        val latch=CountDownLatch(1);var result=-1
                        compose.runOnIdle {
                            val canvas=checkNotNull(find(compose.activity.window.decorView,RemoteCanvas::class.java))
                            bitmap=Bitmap.createBitmap(canvas.width,canvas.height,Bitmap.Config.ARGB_8888)
                            PixelCopy.request(canvas,bitmap,{result=it;latch.countDown()},Handler(Looper.getMainLooper()))
                        }
                        check(latch.await(3,TimeUnit.SECONDS)&&result==PixelCopy.SUCCESS)
                        File(context.cacheDir,"screen-video.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
                        bitmap.recycle()
                    } else compose.runOnIdle {
                        when(op) {
                            "tap"->model.launch{for(button in listOf(1,0)){model.send(session.id,obj("kind" to "pointer","x" to action.getInt("x"),"y" to action.getInt("y"),"buttons" to button));delay(80)}}
                            "text"->{
                                val text=action.getString("text");check(text.length<=32&&text.all{it.code in 32..126})
                                val host=checkNotNull(find(compose.activity.window.decorView,RemoteKeyboardHost::class.java))
                                val editor=checkNotNull(find(host,RemoteKeyboardInput::class.java))
                                editor.onCreateInputConnection(EditorInfo())!!.commitText(text,1)
                            }
                            "keyboard"->find(compose.activity.window.decorView,RemoteKeyboardHost::class.java)?.toggleKeyboard()
                            "backspace"->repeat(action.optInt("count",1).coerceIn(1,32)){model.key(session,0xff08)}
                            "finish"->finish=true
                            else->error("Unsupported diagnostic action")
                        }
                    }
                    done=action.getInt("id")
                }
                val report=compose.runOnIdle{obj("id" to done,"frames" to session.frameRevision,"fps" to session.renderedFPS,"status" to session.status,"error" to model.error,"rendered" to session.renderedFrames,"media" to session.mediaDiagnostics,"renderer" to session.rendererInfo)}
                val temporary=File(context.cacheDir,"screen-video-state.tmp")
                temporary.writeText(report.toString());temporary.renameTo(state)
                if(finish)break
                Thread.sleep(100)
            }
        } finally {
            runBlocking{withContext(Dispatchers.Main){model.close(session)}}
            fixture.delete();command.delete()
        }
    }
}
