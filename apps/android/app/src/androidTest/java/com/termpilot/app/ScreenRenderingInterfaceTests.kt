package com.termpilot.app

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.ConcurrentLinkedQueue
import android.view.MotionEvent
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import kotlin.concurrent.thread

/** Checks the actual screen pixels, beyond receiving the first decoded frame. */
class ScreenRenderingInterfaceTests {
    @get:Rule val compose=createAndroidComposeRule<MainActivity>()
    @Test fun touchpadCursorOnStaticDesktopMatchesRemoteClickAndViewport() {
        val model=compose.activity.mobileModel
        compose.waitUntil(15000){model.ready}
        AnimatedRfbServer().use { server ->
            server.color.set(Color.rgb(20,20,20))
            runBlocking {withContext(Dispatchers.Main){model.connect(obj("id" to UUID.randomUUID().toString(),"label" to "Cursor test","hostname" to "127.0.0.1","port" to server.port,"connectionKind" to "screenSharing","mode" to "standardVNC"))}}
            try {
                compose.waitUntil(15000){model.current?.connected==true}
                val session=compose.runOnIdle{model.current!!}
                fun find(view:View):RemoteCanvas? {
                    if(view is RemoteCanvas)return view
                    if(view is ViewGroup)for(i in 0 until view.childCount)find(view.getChildAt(i))?.let{return it}
                    return null
                }
                lateinit var canvas:RemoteCanvas
                compose.waitUntil(10000){compose.runOnIdle{find(compose.activity.window.decorView)?.also{canvas=it}!=null&&session.renderedFrames>2}}
                server.paused=true
                Thread.sleep(250)
                val frames=compose.runOnIdle{session.renderedFrames}
                compose.onNodeWithText("触控板").performClick()
                compose.runOnIdle {
                    assertTrue(canvas.cursorOverlay.isVisible)
                    assertEquals(canvas.width/2f,canvas.cursorOverlay.tip.x,.01f)
                    assertEquals(canvas.height/2f,canvas.cursorOverlay.tip.y,.01f)
                }
                fun checkVisible(name:String){
                    lateinit var bitmap:Bitmap
                    val latch=CountDownLatch(1);var result=-1
                    var px=0;var py=0
                    compose.runOnIdle {
                        val location=IntArray(2);canvas.getLocationInWindow(location)
                        val dp=canvas.resources.displayMetrics.density
                        px=(location[0]+canvas.cursorOverlay.tip.x+2*dp).toInt()
                        py=(location[1]+canvas.cursorOverlay.tip.y+8*dp).toInt()
                        val decor=compose.activity.window.decorView
                        bitmap=Bitmap.createBitmap(decor.width,decor.height,Bitmap.Config.ARGB_8888)
                        PixelCopy.request(compose.activity.window,bitmap,{result=it;latch.countDown()},Handler(Looper.getMainLooper()))
                    }
                    check(latch.await(3,TimeUnit.SECONDS));assertEquals(PixelCopy.SUCCESS,result)
                    val color=bitmap.getPixel(px,py)
                    java.io.File(compose.activity.cacheDir,"cursor-$name.png").outputStream().use{bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
                    bitmap.recycle()
                    assertTrue("White cursor must be visible above the actual GL surface ($color)",Color.red(color)>220&&Color.green(color)>220&&Color.blue(color)>220)
                }
                Thread.sleep(150);checkVisible("initial")
                compose.runOnIdle {
                    val now=android.os.SystemClock.uptimeMillis();val x=canvas.width/2f;val y=canvas.height/2f
                    listOf(Triple(MotionEvent.ACTION_DOWN,x,now),Triple(MotionEvent.ACTION_MOVE,x+40,now+50),Triple(MotionEvent.ACTION_UP,x+40,now+100)).forEach{(action,px,time)->
                        MotionEvent.obtain(now,time,action,px,y,0).also{canvas.dispatchTouchEvent(it);it.recycle()}
                    }
                }
                compose.waitUntil(5000){server.pointers.any{it.second>160}}
                val moved=compose.runOnIdle{session.remoteCursor!!}
                // A tap clicks at the visible pointer, not at the finger's absolute screen position.
                compose.runOnIdle {
                    val now=android.os.SystemClock.uptimeMillis()
                    for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP))MotionEvent.obtain(now,now+10,action,30f,30f,0).also{canvas.dispatchTouchEvent(it);it.recycle()}
                }
                compose.waitUntil(5000){server.pointers.any{it.first==1}}
                val click=server.pointers.last{it.first==1}
                assertEquals(moved.x.toInt(),click.second);assertEquals(moved.y.toInt(),click.third)
                compose.runOnIdle {
                    canvas.setViewport(2f,-20f,30f)
                    val scale=minOf(canvas.width/320f,canvas.height/180f)*2
                    assertEquals((canvas.width-320*scale)/2-20+click.second*scale,canvas.cursorOverlay.tip.x,.01f)
                    assertEquals((canvas.height-180*scale)/2+30+click.third*scale,canvas.cursorOverlay.tip.y,.01f)
                }
                Thread.sleep(150);checkVisible("moved-zoomed")
                compose.runOnIdle {assertEquals("Local pointer movement must not count as video frames",frames,session.renderedFrames)}
                compose.onNodeWithText("触控板").performClick()
                compose.runOnIdle {assertFalse(canvas.cursorOverlay.isVisible)}
                assertNull(model.error)
            }finally{runBlocking{withContext(Dispatchers.Main){model.current?.let{model.close(it)}}}}
        }
    }
    @Test fun aFailedControlEventDoesNotStopFollowingVideoFrames()=runBlocking {
        val events=ArrayDeque(listOf(
            Packet(obj("kind" to "frame","tile" to 0),byteArrayOf(1)),
            Packet(obj("kind" to "clipboardFiles"),byteArrayOf()),
            Packet(obj("kind" to "frame","tile" to 0),byteArrayOf(2)),
        ))
        val frames=RemoteFrames();var errors=0;var notifications=0
        frames.attach{notifications++}
        try {
            withTimeout(2000){receiveMobileEvents(
                {if(events.isEmpty())throw CancellationException("Fixture complete")else events.removeFirst()},
                {if(it.header.optString("kind")=="frame")frames.publish(it)else org.json.JSONArray(String(it.payload))},
                {errors++},
            )}
        } catch(_:CancellationException){}
        assertEquals(1,errors)
        assertEquals(2L,frames.revision)
        assertEquals(3,notifications)
        assertArrayEquals(byteArrayOf(2),frames.snapshot().getValue(0).packet.payload)
    }
    @Test fun receivedFramesContinueUpdatingTheDisplayedSurface() {
        val model=compose.activity.mobileModel
        compose.waitUntil(15000){model.ready}
        AnimatedRfbServer().use { server ->
            runBlocking { withContext(Dispatchers.Main) { model.connect(obj("id" to UUID.randomUUID().toString(),"label" to "Render verification","hostname" to "127.0.0.1","port" to server.port,"connectionKind" to "screenSharing","mode" to "standardVNC")) } }
            try {
                compose.waitUntil(15000){model.current?.connected==true}
                val session=compose.runOnIdle{model.current!!}
                fun find(view:View):RemoteCanvas? {
                    if(view is RemoteCanvas)return view
                    if(view is ViewGroup)for(i in 0 until view.childCount)find(view.getChildAt(i))?.let{return it}
                    return null
                }
                lateinit var canvas:RemoteCanvas
                compose.waitUntil(10000){compose.runOnIdle{find(compose.activity.window.decorView)?.also{canvas=it}!=null}}
                fun centerPixel():Int {
                    lateinit var bitmap:Bitmap
                    val latch=CountDownLatch(1);var result=-1
                    compose.runOnIdle {
                        bitmap=Bitmap.createBitmap(canvas.width,canvas.height,Bitmap.Config.ARGB_8888)
                        PixelCopy.request(canvas,bitmap,{result=it;latch.countDown()},Handler(Looper.getMainLooper()))
                    }
                    check(latch.await(3,TimeUnit.SECONDS)){"PixelCopy timed out"}
                    if(result!=PixelCopy.SUCCESS){bitmap.recycle();return Color.TRANSPARENT}
                    val pixel=bitmap.getPixel(bitmap.width/2,bitmap.height/2);bitmap.recycle();return pixel
                }
                for(color in listOf(Color.RED,Color.BLUE,Color.GREEN)){
                    server.color.set(color)
                    val before=compose.runOnIdle{session.frameRevision}
                    compose.waitUntil(10000){session.frameRevision>before+3}
                    val deadline=System.nanoTime()+5_000_000_000
                    var observed=Color.TRANSPARENT
                    do {observed=centerPixel();if(observed==color)break;Thread.sleep(50)}while(System.nanoTime()<deadline)
                    assertEquals("Decoded frames=${session.frameRevision}; screen must change from first frame",color,observed)
                }
                compose.waitUntil(5000){session.renderedFPS>0}
                assertNull(model.error)
                // A static remote desktop sends no replacement frame when Android
                // recreates its EGL surface (background, orientation, view changes).
                server.paused=true
                Thread.sleep(250)
                compose.runOnIdle {canvas.preserveEGLContextOnPause=false;canvas.onPause();canvas.onResume()}
                val deadline=System.nanoTime()+3_000_000_000L
                var restored=Color.TRANSPARENT
                do {restored=centerPixel();if(restored==Color.GREEN)break;Thread.sleep(50)}while(System.nanoTime()<deadline)
                assertEquals("Retained frame must survive EGL context recreation without network traffic",Color.GREEN,restored)
                println("Visible OpenGL pixels changed red -> blue -> green, with advancing frame count and FPS.")
            } finally {runBlocking{withContext(Dispatchers.Main){model.current?.let{model.close(it)}}}}
        }
    }

    @Test fun highPerformanceTilesKeepTheirLatestPixelsAndUseActualChromaSize() {
        val model=compose.activity.mobileModel
        compose.waitUntil(15000){model.ready}
        val session=Session(0,obj("label" to "Tile verification"),"screen","")
        lateinit var canvas:RemoteCanvas
        compose.runOnIdle {
            compose.activity.setContent{AndroidView(factory={RemoteCanvas(it,model,session).also{view->canvas=view}},modifier=Modifier.fillMaxSize())}
        }
        compose.waitUntil(5000){runCatching{canvas.width>0&&canvas.height>0}.getOrDefault(false)}
        fun tile(index:Int,y:Int,subsampled:Boolean) {
            val w=1920;val h=270;val cw=if(subsampled)w/2 else w;val ch=if(subsampled)h/2 else h
            val data=ByteArray(w*h+cw*ch*2){if(it<w*h)y.toByte()else 128.toByte()}
            session.frames.publish(Packet(obj("tile" to index,"width" to w,"height" to h,"biplanar" to true,
                "yStride" to w,"uvStride" to cw*2,"chromaWidth" to cw,"chromaHeight" to ch,"yLength" to w*h),data))
        }
        fun displayed():List<Int> {
            lateinit var bitmap:Bitmap
            val latch=CountDownLatch(1);var result=-1
            compose.runOnIdle {
                bitmap=Bitmap.createBitmap(canvas.width,canvas.height,Bitmap.Config.ARGB_8888)
                PixelCopy.request(canvas,bitmap,{result=it;latch.countDown()},Handler(Looper.getMainLooper()))
            }
            check(latch.await(3,TimeUnit.SECONDS)){"PixelCopy timed out"}
            if(result!=PixelCopy.SUCCESS){bitmap.recycle();return listOf(-1,-1,-1,-1)}
            val scale=minOf(bitmap.width/1920f,bitmap.height/1080f)
            val top=(bitmap.height-1080*scale)/2
            return (0..3).map{Color.red(bitmap.getPixel(bitmap.width/2,(top+(it+.5f)*270*scale).toInt()))}.also{bitmap.recycle()}
        }
        fun awaitPixels(expected:List<Int>) {
            val deadline=System.nanoTime()+5_000_000_000L
            var actual=listOf<Int>()
            do {actual=displayed();if(actual.zip(expected).all{(a,b)->kotlin.math.abs(a-b)<=2})return;Thread.sleep(50)}while(System.nanoTime()<deadline)
            assertEquals("Actual rendered tile pixels",expected,actual)
        }
        listOf(40,90,140,190).forEachIndexed{i,y->tile(i,y,false)}
        awaitPixels(listOf(40,90,140,190))
        // Only one region changes, and it switches from 4:4:4 to 4:2:0 chroma.
        tile(2,230,true);awaitPixels(listOf(40,90,230,190))
        compose.runOnIdle{canvas.preserveEGLContextOnPause=false;canvas.onPause();canvas.onResume()}
        awaitPixels(listOf(40,90,230,190))
        assertNull(model.error)
    }
}

private class AnimatedRfbServer:AutoCloseable {
    private val server=ServerSocket(0,1,InetAddress.getByName("127.0.0.1"))
    val port get()=server.localPort
    val color=AtomicInteger(Color.RED)
    val pointers=ConcurrentLinkedQueue<Triple<Int,Int,Int>>()
    @Volatile var paused=false
    @Volatile private var socket:Socket?=null
    @Volatile private var closed=false
    private val worker=thread(isDaemon=true,name="Animated RFB fixture"){
        try{server.accept().use { client ->
            socket=client;client.tcpNoDelay=true
            val input=DataInputStream(client.getInputStream());val output=DataOutputStream(client.getOutputStream())
            fun bytes(n:Int)=ByteArray(n).also{input.readFully(it)}
            output.writeBytes("RFB 003.008\n");bytes(12);output.write(byteArrayOf(1,1));check(input.readUnsignedByte()==1)
            output.writeInt(0);bytes(1);output.writeShort(320);output.writeShort(180);output.write(ByteArray(16));output.writeInt(4);output.writeBytes("Test")
            while(!closed){when(input.readUnsignedByte()){
                0->bytes(19)
                2->{bytes(1);bytes(input.readUnsignedShort()*4)}
                3->{bytes(9);if(paused)continue;Thread.sleep(40);val c=color.get();val pixels=ByteArray(320*180*4)
                    for(i in pixels.indices step 4){pixels[i]=Color.blue(c).toByte();pixels[i+1]=Color.green(c).toByte();pixels[i+2]=Color.red(c).toByte()}
                    output.write(byteArrayOf(0,0,0,1));output.writeShort(0);output.writeShort(0);output.writeShort(320);output.writeShort(180);output.writeInt(0);output.write(pixels);output.flush()}
                4->bytes(7)
                5->pointers.add(Triple(input.readUnsignedByte(),input.readUnsignedShort(),input.readUnsignedShort()))
                6->{bytes(3);bytes(input.readInt())}
                else->error("Unknown client message")
            }}
        }}catch(error:Exception){if(!closed)error.printStackTrace()}
    }
    override fun close(){closed=true;socket?.close();server.close();worker.join(2000)}
}
