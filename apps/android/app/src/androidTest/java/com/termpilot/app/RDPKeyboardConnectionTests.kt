package com.termpilot.app

import android.content.ContextWrapper
import android.view.inputmethod.EditorInfo
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/** Opt-in fixture: Windows test account, trusted certificate pin, and private credentials. */
class RDPKeyboardConnectionTests {
    @Test fun imeAndRapidInputReachWindowsInOrder()=runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val fixture=File(context.cacheDir,"rdp-keyboard-fixture.json")
        assumeTrue("No authorized RDP keyboard fixture",fixture.exists())
        val root=File(context.cacheDir,"rdp-keyboard-${UUID.randomUUID()}").apply{mkdirs()}
        val runtime=MobileRuntime(object:ContextWrapper(context){override fun getFilesDir()=root})
        var session:Long?=null
        try {
            val command=JSONObject(fixture.readText()).getJSONObject("rdp")
                .put("cacheDirectory",File(root,"files").path)
            assertEquals(64,command.getString("certificateSHA256").length)
            val id=runtime.call(obj("method" to "session.open","protocol" to "rdp","command" to command)).getLong("session")
            session=id
            suspend fun send(command:JSONObject){runtime.call(obj("method" to "session.send","session" to id,"command" to command))}
            suspend fun waitFor(kind:String,expected:String?=null):Packet=withTimeout(45000) {
                while(true){
                    val packet=runtime.poll()?:continue
                    val event=packet.header
                    val type=event.optString("kind")
                    check(type !in listOf("error","certificate","disconnected")){"RDP stopped at $type"}
                    if(type==kind&&(expected==null||event.optString("text",String(packet.payload))==expected)) return@withTimeout packet
                }
                error("Unreachable")
            }
            suspend fun key(code:Int){send(obj("kind" to "key","key" to code,"down" to true));send(obj("kind" to "key","key" to code,"down" to false))}
            suspend fun chord(modifier:Int,code:Int){send(obj("kind" to "key","key" to modifier,"down" to true));key(code);send(obj("kind" to "key","key" to modifier,"down" to false))}
            waitFor("frame")
            delay(1200)
            // Use the Run field as a temporary text receiver. Never press Enter;
            // Escape dismisses the field without executing anything remotely.
            chord(0xffeb,'r'.code);delay(1500);chord(0xffe3,'a'.code)
            withContext(Dispatchers.Main.immediate) {
                coroutineScope {
                    val scope=this
                    val view=RemoteKeyboardInput(context,
                        {text->scope.launch{send(obj("kind" to "text","text" to text))}},
                        {code->scope.launch{key(code)}})
                    val connection=view.onCreateInputConnection(EditorInfo())!!
                    connection.setComposingText("中文",1)
                    connection.finishComposingText()
                    // Each character starts a separate UI callback, as actual typing does.
                    "-TermPilot-AbC123!".forEach{connection.commitText(it.toString(),1)}
                }
            }
            delay(400);chord(0xffe3,'a'.code);chord(0xffe3,'c'.code)
            waitFor("clipboard","中文-TermPilot-AbC123!")
            key(0xff57) // End: clear selection before exercising soft-keyboard deletion.
            withContext(Dispatchers.Main.immediate) {
                coroutineScope {
                    val scope=this
                    val view=RemoteKeyboardInput(context,{}, {code->scope.launch{key(code)}})
                    view.onCreateInputConnection(EditorInfo())!!.deleteSurroundingText(1,0)
                }
            }
            delay(400);chord(0xffe3,'a'.code);chord(0xffe3,'c'.code)
            waitFor("clipboard","中文-TermPilot-AbC123")
            key(0xff1b)
            println("RDP Windows readback passed: IME commit, mixed-case text, rapid input, soft-keyboard deletion, Ctrl+A/C.")
        } finally {
            session?.let { id->
                runCatching {
                    runtime.call(obj("method" to "session.send","session" to id,"command" to obj("kind" to "key","key" to 0xff1b,"down" to true)))
                    runtime.call(obj("method" to "session.send","session" to id,"command" to obj("kind" to "release")))
                    runtime.call(obj("method" to "session.close","session" to id))
                }
            }
            runtime.close();root.deleteRecursively();fixture.delete()
        }
    }
}
