package com.termpilot.app

import android.content.ContextWrapper
import android.view.inputmethod.EditorInfo
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/** Exercise the shipped JNI library, not a mocked text-to-key conversion. */
class ScreenKeyboardProtocolTests {
    @Test fun committedInputReachesRfbServerInOrder()=runBlocking {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        val root=File(context.cacheDir,"screen-keys-${UUID.randomUUID()}").apply{mkdirs()}
        val runtime=MobileRuntime(object:ContextWrapper(context){override fun getFilesDir()=root})
        RfbKeyboardServer().use { server ->
            try {
                val session=runtime.call(obj("method" to "session.open","protocol" to "screen","command" to obj(
                    "kind" to "connect","mode" to "standardVNC","host" to "127.0.0.1","port" to server.port
                ))).getLong("session")
                val queue=SessionCommandQueue()
                suspend fun send(commands:List<JSONObject>){queue.send(commands){command->runtime.call(obj("method" to "session.send","session" to session,"command" to command))}}
                withTimeout(15000) {
                    while(true){
                        val event=runtime.poll()?.header?:continue
                        check(event.optString("kind") !in listOf("error","disconnected")){event.toString()}
                        if(event.optString("kind")=="connected")break
                    }
                }
                withContext(Dispatchers.Main.immediate){
                    coroutineScope {
                        val scope=this
                        val input=RemoteKeyboardInput(context,
                            {value->scope.launch{send(listOf(obj("kind" to "text","text" to value)))}},
                            {key->scope.launch{
                                send(remoteKeyPress(key))
                            }})
                        val connection=input.onCreateInputConnection(EditorInfo())!!
                        "aA1!".forEach{connection.commitText(it.toString(),1)}
                        connection.setComposingText("中文",1)
                        connection.finishComposingText()
                        connection.commitText("😀",1)
                        connection.deleteSurroundingText(1,0)
                        connection.performEditorAction(EditorInfo.IME_ACTION_DONE)
                        scope.launch{send(remoteKeyPress('a'.code,0xffe7))}
                        scope.launch{send(listOf(obj("kind" to "text","text" to "z")))}
                    }
                }
                val symbols=listOf(0x61,0x41,0x31,0x21,0x01004e2d,0x01006587,0x0101f600,0xff08,0xff0d)
                val expected=symbols.flatMap{listOf(it to true,it to false)}+listOf(0xffe7 to true,0x61 to true,0x61 to false,0xffe7 to false,0x7a to true,0x7a to false)
                withTimeout(10000){while(server.keys.size<expected.size){server.failure.get()?.let{throw it};delay(10)}}
                assertEquals(expected,server.snapshot())
                runtime.call(obj("method" to "session.close","session" to session))
                println("Android JNI -> RFB verified: ASCII, IME commit, Unicode, soft Backspace and Enter.")
            } finally { runtime.close();root.deleteRecursively() }
        }
    }
}

private class RfbKeyboardServer:AutoCloseable {
    private val listener=ServerSocket(0,1,InetAddress.getByName("127.0.0.1"))
    val port get()=listener.localPort
    val keys=Collections.synchronizedList(mutableListOf<Pair<Int,Boolean>>())
    val failure=AtomicReference<Throwable?>(null)
    @Volatile private var closed=false
    @Volatile private var client:Socket?=null
    private val worker=thread(name="RFB keyboard fixture",isDaemon=true){
        try {listener.accept().use { socket ->
            client=socket;socket.soTimeout=15000
            val input=DataInputStream(socket.getInputStream())
            val output=DataOutputStream(socket.getOutputStream())
            fun bytes(n:Int)=ByteArray(n).also{input.readFully(it)}
            output.write("RFB 003.008\n".toByteArray())
            check(String(bytes(12))=="RFB 003.008\n")
            output.write(byteArrayOf(1,1));check(input.readUnsignedByte()==1)
            output.writeInt(0);check(input.readUnsignedByte()==1)
            output.writeShort(1);output.writeShort(1);output.write(ByteArray(16));output.writeInt(4);output.writeBytes("Test")
            check(bytes(20)[0].toInt()==0)
            check(input.readUnsignedByte()==2);input.readUnsignedByte();bytes(input.readUnsignedShort()*4)
            check(bytes(10)[0].toInt()==3)
            output.write(byteArrayOf(0,0,0,1))
            output.writeShort(0);output.writeShort(0);output.writeShort(1);output.writeShort(1);output.writeInt(0);output.writeInt(0)
            while(!closed){
                when(input.readUnsignedByte()){
                    3->bytes(9)
                    4->{val down=input.readUnsignedByte()!=0;input.readUnsignedShort();keys.add(input.readInt() to down)}
                    5->bytes(5)
                    else->error("Unexpected RFB client message")
                }
            }
        }} catch(_:EOFException){} catch(error:Throwable){if(!closed)failure.set(error)}
    }
    fun snapshot()=synchronized(keys){keys.toList()}
    override fun close(){closed=true;client?.close();listener.close();worker.join(2000);failure.get()?.let{throw it}}
}
