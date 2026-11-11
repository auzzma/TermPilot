package com.termpilot.app

import android.content.ContextWrapper
import android.graphics.Bitmap
import android.view.inputmethod.EditorInfo
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/** Opt-in locked-screen probe. Never sends Enter or uses the login password as input. */
class ScreenKeyboardMacDiagnostics {
    @Test fun inspectSavedMacInput()=runBlocking<Unit> {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val fixture=File(context.cacheDir,"mobile-screen-fixture.json")
        assumeTrue(fixture.exists())
        val mode=InstrumentationRegistry.getArguments().getString("screenMode","standardVNC")
        val allowFrameless=InstrumentationRegistry.getArguments().getString("allowFrameless")=="true"
        val root=File(context.cacheDir,"screen-keyboard-${UUID.randomUUID()}").apply{mkdirs()}
        val commandFile=File(context.cacheDir,"screen-keyboard-command.json")
        val stateFile=File(context.cacheDir,"screen-keyboard-state.json")
        commandFile.delete();stateFile.delete()
        val runtime=MobileRuntime(object:ContextWrapper(context){override fun getFilesDir()=root})
        val frames=mutableMapOf<Int,Packet>()
        try {
            val config=JSONObject(fixture.readText()).getJSONObject("screen").put("mode",mode)
                .put("lockDirectory",File(root,"lock").path)
            val id=runtime.call(obj("method" to "session.open","protocol" to "screen","command" to config)).getLong("session")
            val queue=SessionCommandQueue()
            suspend fun send(commands:List<JSONObject>){queue.send(commands){runtime.call(obj("method" to "session.send","session" to id,"command" to it))}}
            suspend fun key(code:Int,modifier:Int?=null){check(code!=0xff0d);send(remoteKeyPress(code,modifier))}
            var ready=false
            var connected=false
            withTimeout(480000){
                while(true){
                    val packet=runtime.poll()
                    packet?.let{
                        when(it.header.optString("kind")){
                            "error","disconnected"->error(it.header.optString("code","Disconnected"))
                            "frame"->frames[it.header.optInt("tile")]=it
                            "connected"->connected=true
                        }
                    }
                    if(!ready&&(frames.size==(if(mode=="highPerformance")4 else 1)||allowFrameless&&connected)){
                        ready=true;if(frames.isNotEmpty())capture(frames,File(context.cacheDir,"screen-keyboard.png"))
                        stateFile.writeText(obj("phase" to "ready","mode" to mode).toString())
                    }
                    if(ready&&commandFile.exists()){
                        val command=JSONObject(commandFile.readText());commandFile.delete()
                        when(command.getString("op")){
                            "tap"->{val x=command.getInt("x");val y=command.getInt("y");send(listOf(obj("kind" to "pointer","x" to x,"y" to y,"buttons" to 1),obj("kind" to "pointer","x" to x,"y" to y,"buttons" to 0)))}
                            "text"->{val text=command.getString("text");check(text.length<=32&&!text.contains('\r')&&!text.contains('\n'))
                                withContext(Dispatchers.Main.immediate){coroutineScope{val scope=this
                                    val view=RemoteKeyboardInput(context,{value->scope.launch{send(listOf(obj("kind" to "text","text" to value)))}},{code->scope.launch{key(code)}})
                                    view.onCreateInputConnection(EditorInfo())!!.commitText(text,1)
                                }}
                            }
                            "backspace"->repeat(command.optInt("count",1).coerceIn(1,32)){key(0xff08)}
                            "heldKey"->{
                                val code=command.getInt("key");check(code in 32..126||code==0xff08)
                                send(listOf(obj("kind" to "key","key" to code,"down" to true)))
                                delay(100)
                                send(listOf(obj("kind" to "key","key" to code,"down" to false)))
                            }
                            "pacedText"->{
                                val text=command.getString("text");check(text.length<=32&&text.all{it.code in 32..126})
                                val interval=command.optLong("interval",20).coerceIn(10,100)
                                for(char in text){
                                    send(listOf(obj("kind" to "key","key" to char.code,"down" to true)))
                                    delay(interval)
                                    send(listOf(obj("kind" to "key","key" to char.code,"down" to false)))
                                    delay(interval)
                                }
                            }
                            "capture"->capture(frames,File(context.cacheDir,"screen-keyboard.png"))
                            "finish"->break
                            else->error("Unsupported diagnostic action")
                        }
                        stateFile.writeText(obj("phase" to "done","id" to command.getInt("id"),"mode" to mode).toString())
                    }
                }
            }
            send(listOf(obj("kind" to "release")))
            runtime.call(obj("method" to "session.close","session" to id))
        } finally {runtime.close();root.deleteRecursively();fixture.delete();commandFile.delete()}
    }

    private fun capture(frames:Map<Int,Packet>,file:File){
        val width=frames.values.maxOf{it.header.getInt("width")}
        val height=frames.values.sumOf{it.header.getInt("height")}
        val image=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888)
        var top=0
        for((_,packet) in frames.toSortedMap()){
            val h=packet.header;val w=h.getInt("width");val rows=h.getInt("height");val data=packet.payload
            fun at(i:Int)=data[i].toInt() and 255
            val pixels=IntArray(w*rows)
            for(y in 0 until rows)for(x in 0 until w){
                val r:Int;val g:Int;val b:Int
                if(h.optBoolean("biplanar")){
                    val yy=at(y*h.getInt("yStride")+x).toDouble()
                    val uv=h.getInt("yLength")+(y*h.getInt("chromaHeight")/rows)*h.getInt("uvStride")+(x*h.getInt("chromaWidth")/w)*2
                    val u=at(uv)-128.0;val v=at(uv+1)-128.0
                    r=(yy+1.5748*v).toInt().coerceIn(0,255);g=(yy-.187324*u-.468124*v).toInt().coerceIn(0,255);b=(yy+1.8556*u).toInt().coerceIn(0,255)
                }else{val i=y*h.optInt("yStride",w*4)+x*4;b=at(i);g=at(i+1);r=at(i+2)}
                pixels[y*w+x]=(255 shl 24) or (r shl 16) or (g shl 8) or b
            }
            image.setPixels(pixels,0,w,0,top,w,rows);top+=rows
        }
        file.outputStream().use{image.compress(Bitmap.CompressFormat.PNG,100,it)};image.recycle()
    }
}
