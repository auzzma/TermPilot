package com.termpilot.app

import android.content.Context
import android.opengl.GLES20 as GL
import android.opengl.GLSurfaceView
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONObject
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Retains the latest decoded texture of every tile; a busy UI never drops other regions. */
class RemoteCanvas(context:Context,val model:AppModel,val session:Session):GLSurfaceView(context),GLSurfaceView.Renderer {
    private class Plane(val texture:Int) {
        var bytes:ByteBuffer?=null
        var width=0;var height=0;var format=0
    }
    private class Tile(val planes:List<Plane>) {
        var revision=-1L
        var header=JSONObject()
    }
    private val tiles=sortedMapOf<Int,Tile>()
    private val frameAvailable:()->Unit={requestRender()}
    private var reportedError:String?=null
    private var drawn=0
    private var sampled=System.nanoTime()
    private var program=0
    @Volatile private var desktopWidth=1920
    @Volatile private var desktopHeight=1080
    @Volatile private var zoom=1f
    private var surfaceWidth=1;private var surfaceHeight=1
    private val cursorX get()=(session.remoteCursor?.x?:desktopWidth/2f).coerceIn(0f,(desktopWidth-1).toFloat())
    private val cursorY get()=(session.remoteCursor?.y?:desktopHeight/2f).coerceIn(0f,(desktopHeight-1).toFloat())
    private val lastX get()=cursorX.toInt()
    private val lastY get()=cursorY.toInt()
    internal val cursorOverlay=RemoteCursorDrawable(resources.displayMetrics.density)
    private var pressed=false
    private var fingerX=0f;private var fingerY=0f;private var downX=0f;private var downY=0f
    @Volatile private var offsetX=0f
    @Volatile private var offsetY=0f
    private var panX=0f;private var panY=0f;private var panning=false;private var longPressed=false
    private val gestures=android.view.GestureDetector(context,object:android.view.GestureDetector.SimpleOnGestureListener(){override fun onDown(e:MotionEvent)=true;override fun onLongPress(e:MotionEvent){longPressed=true;release();sendPointer(lastX,lastY,2);sendPointer(lastX,lastY,0)}})
    private val vertices=ByteBuffer.allocateDirect(64).order(ByteOrder.nativeOrder()).asFloatBuffer().apply{put(floatArrayOf(-1f,1f,0f,0f,-1f,-1f,0f,1f,1f,1f,1f,0f,1f,-1f,1f,1f));position(0)}
    private val scaleGesture=ScaleGestureDetector(context,object:ScaleGestureDetector.SimpleOnScaleGestureListener(){override fun onScale(d:ScaleGestureDetector):Boolean{release();setViewport(zoom*d.scaleFactor,offsetX,offsetY);return true}})
    init{isFocusableInTouchMode=true;setEGLContextClientVersion(2);setRenderer(this);renderMode=RENDERMODE_WHEN_DIRTY;preserveEGLContextOnPause=true;contentDescription="远程桌面，触摸操作，双指缩放";overlay.add(cursorOverlay);updateCursor()}
    override fun onAttachedToWindow(){super.onAttachedToWindow();session.frames.attach(frameAvailable);updateCursor()}
    override fun onSizeChanged(w:Int,h:Int,oldw:Int,oldh:Int){super.onSizeChanged(w,h,oldw,oldh);updateCursor()}
    internal fun updateCursor(){
        if(session.remoteCursor!=null)session.remoteCursor=RemoteCursorPosition(cursorX,cursorY)
        val scale=minOf(width.toFloat()/desktopWidth,height.toFloat()/desktopHeight)*zoom
        val x=(width-desktopWidth*scale)/2+offsetX+lastX*scale
        val y=(height-desktopHeight*scale)/2+offsetY+lastY*scale
        cursorOverlay.setBounds(0,0,width,height)
        cursorOverlay.place(x,y,session.touchpad&&!session.localDrag&&width>0&&height>0&&x>=0&&y>=0&&x<width&&y<height)
    }
    internal fun setViewport(value:Float,x:Float,y:Float){zoom=value.coerceIn(1f,4f);offsetX=x;offsetY=y;updateCursor();requestRender()}
    override fun onSurfaceCreated(gl:GL10?,config:EGLConfig?){
        fun shader(type:Int,source:String):Int{val id=GL.glCreateShader(type);GL.glShaderSource(id,source);GL.glCompileShader(id);val ok=IntArray(1);GL.glGetShaderiv(id,GL.GL_COMPILE_STATUS,ok,0);check(ok[0]!=0){GL.glGetShaderInfoLog(id)};return id}
        program=GL.glCreateProgram()
        val vs=shader(GL.GL_VERTEX_SHADER,"attribute vec2 p; attribute vec2 uv; varying vec2 v; void main(){gl_Position=vec4(p,0.,1.);v=uv;}")
        val fs=shader(GL.GL_FRAGMENT_SHADER,"precision mediump float; varying vec2 v; uniform sampler2D image; uniform sampler2D chroma; uniform int mode; void main(){if(mode==0){gl_FragColor=vec4(texture2D(image,v).bgr,1.);}else{float y=texture2D(image,v).r;vec2 c=texture2D(chroma,v).ra-vec2(128./255.);gl_FragColor=vec4(clamp(vec3(y+1.5748*c.y,y-.187324*c.x-.468124*c.y,y+1.8556*c.x),0.,1.),1.);}}")
        GL.glAttachShader(program,vs);GL.glAttachShader(program,fs);GL.glLinkProgram(program);GL.glDeleteShader(vs);GL.glDeleteShader(fs)
        val linked=IntArray(1);GL.glGetProgramiv(program,GL.GL_LINK_STATUS,linked,0)
        check(linked[0]!=0){GL.glGetProgramInfoLog(program)}
        tiles.clear()
        // Context loss invalidates GPU textures, not the retained decoded frames.
        drawn=0;sampled=System.nanoTime();reportedError=null
        val driver="${GL.glGetString(GL.GL_VENDOR)} / ${GL.glGetString(GL.GL_RENDERER)} / ${GL.glGetString(GL.GL_VERSION)}"
        android.util.Log.i("TermPilotVideo",driver)
        post{session.rendererInfo=driver;session.videoError=""}
        requestRender()
    }
    override fun onSurfaceChanged(gl:GL10?,w:Int,h:Int){surfaceWidth=w;surfaceHeight=h}
    private fun upload(target:Plane,p:Packet,plane:Int){
        val h=p.header;val bi=h.optBoolean("biplanar")
        val w=if(plane==0)h.optInt("width")else h.optInt("chromaWidth",h.optInt("width"))
        val height=if(plane==0)h.optInt("height")else h.optInt("chromaHeight",h.optInt("height"))
        val bpp=if(!bi)4 else if(plane==0)1 else 2
        val stride=h.optInt(if(plane==0)"yStride" else "uvStride",w*bpp);val offset=if(plane==0)0 else h.optInt("yLength")
        require(w in 1..8192&&height in 1..8192&&stride>=w*bpp&&offset.toLong()+stride.toLong()*height<=p.payload.size)
        val length=w*height*bpp
        val bytes=target.bytes?.takeIf{it.capacity()>=length}?:ByteBuffer.allocateDirect(length).also{target.bytes=it}
        bytes.clear()
        if(stride==w*bpp)bytes.put(p.payload,offset,length)
        else for(row in 0 until height)bytes.put(p.payload,offset+row*stride,w*bpp)
        bytes.flip();GL.glActiveTexture(GL.GL_TEXTURE0);GL.glBindTexture(GL.GL_TEXTURE_2D,target.texture)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT,1)
        val format=if(!bi)GL.GL_RGBA else if(plane==0)GL.GL_LUMINANCE else GL.GL_LUMINANCE_ALPHA
        if(target.width!=w||target.height!=height||target.format!=format){
            GL.glTexParameteri(GL.GL_TEXTURE_2D,GL.GL_TEXTURE_MIN_FILTER,GL.GL_LINEAR);GL.glTexParameteri(GL.GL_TEXTURE_2D,GL.GL_TEXTURE_MAG_FILTER,GL.GL_LINEAR)
            GL.glTexParameteri(GL.GL_TEXTURE_2D,GL.GL_TEXTURE_WRAP_S,GL.GL_CLAMP_TO_EDGE);GL.glTexParameteri(GL.GL_TEXTURE_2D,GL.GL_TEXTURE_WRAP_T,GL.GL_CLAMP_TO_EDGE)
            GL.glTexImage2D(GL.GL_TEXTURE_2D,0,format,w,height,0,format,GL.GL_UNSIGNED_BYTE,bytes)
        }else GL.glTexSubImage2D(GL.GL_TEXTURE_2D,0,0,0,w,height,format,GL.GL_UNSIGNED_BYTE,bytes)
        val error=GL.glGetError();check(error==GL.GL_NO_ERROR){"OpenGL texture upload 0x${error.toString(16)}"}
        target.width=w;target.height=height;target.format=format
    }
    override fun onDrawFrame(gl:GL10?){
        var updated=false
        for((key,frame) in session.frames.snapshot()){
            if(tiles[key]?.revision==frame.revision)continue
            val packet=frame.packet
            try{val tile=tiles.getOrPut(key){val ids=IntArray(2);GL.glGenTextures(2,ids,0);Tile(ids.map{Plane(it)})};upload(tile.planes[0],packet,0);if(packet.header.optBoolean("biplanar"))upload(tile.planes[1],packet,1);tile.header=packet.header;tile.revision=frame.revision;updated=true
                if(!packet.header.optBoolean("biplanar")){
                    val w=packet.header.optInt("width");val h=packet.header.optInt("height")
                    if(w!=desktopWidth||h!=desktopHeight){desktopWidth=w;desktopHeight=h;post{updateCursor()}}
                }
            }catch(e:Exception){val message="画面缓冲无效：${e.message}";if(reportedError!=message){reportedError=message;android.util.Log.e("TermPilotVideo",message);post{session.videoError=message;model.error=message}}}
        }
        val now=System.nanoTime()
        GL.glViewport(0,0,surfaceWidth,surfaceHeight);GL.glClearColor(.02f,.025f,.035f,1f);GL.glClear(GL.GL_COLOR_BUFFER_BIT);GL.glUseProgram(program)
        val scale=minOf(surfaceWidth.toFloat()/desktopWidth,surfaceHeight.toFloat()/desktopHeight)*zoom
        val left=(surfaceWidth-desktopWidth*scale)/2+offsetX;val top=(surfaceHeight-desktopHeight*scale)/2+offsetY
        for((index,tile)in tiles){if(tile.revision<0)continue;val h=tile.header;val w=(h.optInt("width")*scale).toInt();val height=(h.optInt("height")*scale).toInt();val y=top+index*height
            GL.glViewport(left.toInt(),(surfaceHeight-y-height).toInt(),w,height)
            GL.glActiveTexture(GL.GL_TEXTURE0);GL.glBindTexture(GL.GL_TEXTURE_2D,tile.planes[0].texture);GL.glUniform1i(GL.glGetUniformLocation(program,"image"),0)
            GL.glActiveTexture(GL.GL_TEXTURE1);GL.glBindTexture(GL.GL_TEXTURE_2D,tile.planes[1].texture);GL.glUniform1i(GL.glGetUniformLocation(program,"chroma"),1)
            GL.glUniform1i(GL.glGetUniformLocation(program,"mode"),if(h.optBoolean("biplanar"))1 else 0)
            val pos=GL.glGetAttribLocation(program,"p");val uv=GL.glGetAttribLocation(program,"uv");vertices.position(0);GL.glVertexAttribPointer(pos,2,GL.GL_FLOAT,false,16,vertices);GL.glEnableVertexAttribArray(pos);vertices.position(2);GL.glVertexAttribPointer(uv,2,GL.GL_FLOAT,false,16,vertices);GL.glEnableVertexAttribArray(uv);GL.glDrawArrays(GL.GL_TRIANGLE_STRIP,0,4)
        }
        val error=GL.glGetError()
        if(error!=GL.GL_NO_ERROR){val message="画面绘制失败：OpenGL 0x${error.toString(16)}";if(reportedError!=message){reportedError=message;android.util.Log.e("TermPilotVideo",message);post{session.videoError=message;model.error=message}}}
        else if(updated){drawn++;post{session.renderedFrames++;session.lastRenderedAt=now}}
        if(now-sampled>=1_000_000_000L){val rate=drawn/((now-sampled)/1e9);drawn=0;sampled=now;post{session.renderedFPS=rate}}
    }
    private fun release(){if(pressed){pressed=false;model.launch{model.send(session.id,obj("kind" to "release"))}}}
    override fun onDetachedFromWindow(){session.frames.detach(frameAvailable);release();super.onDetachedFromWindow()}
    private fun sendPointer(x:Int,y:Int,buttons:Int)=sendPointer(x.toFloat(),y.toFloat(),buttons)
    private fun sendPointer(x:Float,y:Float,buttons:Int){
        session.remoteCursor=RemoteCursorPosition(x.coerceIn(0f,(desktopWidth-1).toFloat()),y.coerceIn(0f,(desktopHeight-1).toFloat()))
        updateCursor();pressed=buttons!=0
        val px=lastX;val py=lastY
        model.launch{model.send(session.id,obj("kind" to "pointer","x" to px,"y" to py,"buttons" to buttons))}
    }
    override fun onTouchEvent(e:MotionEvent):Boolean{
        requestFocus();gestures.onTouchEvent(e);scaleGesture.onTouchEvent(e)
        if(e.actionMasked==MotionEvent.ACTION_DOWN){fingerX=e.x;fingerY=e.y;downX=e.x;downY=e.y;longPressed=false}
        if(e.actionMasked==MotionEvent.ACTION_CANCEL||e.actionMasked==MotionEvent.ACTION_UP){
            if(e.actionMasked==MotionEvent.ACTION_UP&&session.touchpad&&!session.dragLocked&&!longPressed&&kotlin.math.abs(e.x-downX)+kotlin.math.abs(e.y-downY)<12){sendPointer(lastX,lastY,1);sendPointer(lastX,lastY,0)}
            if(!session.dragLocked||e.actionMasked==MotionEvent.ACTION_CANCEL)release()
            panning=false
            if(session.localDrag){session.localDrag=false;model.launch{model.send(session.id,obj("kind" to if(e.actionMasked==MotionEvent.ACTION_UP)"dragDrop" else "dragCancel"))}};return true
        }
        if(e.pointerCount==2){release();val x=(e.getX(0)+e.getX(1))/2;val y=(e.getY(0)+e.getY(1))/2
            if(panning&&!scaleGesture.isInProgress){offsetX+=x-panX;offsetY+=y-panY;val scale=minOf(width.toFloat()/desktopWidth,height.toFloat()/desktopHeight)*zoom;offsetX=offsetX.coerceIn(-maxOf(0f,(desktopWidth*scale-width)/2),maxOf(0f,(desktopWidth*scale-width)/2));offsetY=offsetY.coerceIn(-maxOf(0f,(desktopHeight*scale-height)/2),maxOf(0f,(desktopHeight*scale-height)/2));updateCursor();requestRender()}
            panX=x;panY=y;panning=true;return true
        }
        if(e.pointerCount!=1||scaleGesture.isInProgress||longPressed){release();return true}
        val scale=minOf(width.toFloat()/desktopWidth,height.toFloat()/desktopHeight)*zoom
        if(session.touchpad&&!session.localDrag){
            val x=cursorX+(e.x-fingerX)/scale;val y=cursorY+(e.y-fingerY)/scale;fingerX=e.x;fingerY=e.y;sendPointer(x,y,if(session.dragLocked)1 else 0)
        }else{
            val x=((e.x-(width-desktopWidth*scale)/2-offsetX)/scale).toInt();val y=((e.y-(height-desktopHeight*scale)/2-offsetY)/scale).toInt()
            if(x in 0 until desktopWidth&&y in 0 until desktopHeight)sendPointer(x,y,if(e.buttonState and MotionEvent.BUTTON_SECONDARY!=0)2 else 1)
        };return true
    }
    override fun onGenericMotionEvent(e:MotionEvent):Boolean{
        if(e.action==MotionEvent.ACTION_SCROLL){val dy=-e.getAxisValue(MotionEvent.AXIS_VSCROLL);if(dy!=0f)model.launch{model.send(session.id,obj("kind" to "scroll","dy" to if(dy>0)1 else -1))};return true}
        if(e.action==MotionEvent.ACTION_HOVER_MOVE){val scale=minOf(width.toFloat()/desktopWidth,height.toFloat()/desktopHeight)*zoom;val x=((e.x-(width-desktopWidth*scale)/2-offsetX)/scale).toInt();val y=((e.y-(height-desktopHeight*scale)/2-offsetY)/scale).toInt();if(x in 0 until desktopWidth&&y in 0 until desktopHeight)sendPointer(x,y,0);return true}
        return super.onGenericMotionEvent(e)
    }
    override fun onKeyDown(keyCode:Int,event:android.view.KeyEvent):Boolean=remoteKey(event,true)||super.onKeyDown(keyCode,event)
    override fun onKeyUp(keyCode:Int,event:android.view.KeyEvent):Boolean=remoteKey(event,false)||super.onKeyUp(keyCode,event)
    private fun remoteKey(e:android.view.KeyEvent,down:Boolean):Boolean {
        val key=remoteKeysym(e)?:return false
        model.launch{model.send(session.id,obj("kind" to "key","key" to key,"down" to down))};return true
    }
}
