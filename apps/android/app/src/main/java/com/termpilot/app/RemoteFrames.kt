package com.termpilot.app

internal data class RawFrameLayout(val generation:Long,val y:Int,val width:Int,val height:Int,val desktopHeight:Int) {
    companion object {
        fun read(packet:Packet):RawFrameLayout {
            val h=packet.header;val w=h.optInt("width");val height=h.optInt("height");val tile=h.optInt("tile")
            require(h.optString("pixelFormat")=="bgrx"&&w in 1..8192&&height in 1..8192&&tile in 0..15)
            require(w.toLong()*height<=16_777_216&&h.optInt("yStride")==w*4&&packet.payload.size.toLong()==w.toLong()*height*4)
            if(!h.has("rawGeneration")) {
                require(tile==0&&!h.has("originY")&&!h.has("desktopWidth")&&!h.has("desktopHeight"))
                return RawFrameLayout(0,0,w,height,height)
            }
            val generation=h.optLong("rawGeneration");val desktop=h.optInt("desktopHeight");val y=h.optInt("originY",-1)
            val rows=maxOf(64,(desktop+15)/16)
            require(generation>0&&desktop in 1..8192&&h.optInt("desktopWidth")==w&&w.toLong()*desktop<=16_777_216)
            require(y==tile*rows&&y<desktop&&height==minOf(rows,desktop-y))
            return RawFrameLayout(generation,y,w,height,desktop)
        }
    }
}

/** Latest decoded frame per tile, retained across view/EGL recreation. */
internal class RemoteFrames {
    data class Frame(val revision:Long,val packet:Packet)
    private val latest=sortedMapOf<Int,Frame>()
    private var observer:(()->Unit)?=null
    private var rawGeneration=-1L
    @Volatile var revision=0L
        private set

    fun publish(packet:Packet):Boolean {
        val layout=if(packet.header.optString("pixelFormat")=="bgrx")runCatching{RawFrameLayout.read(packet)}.getOrNull()?:return false else null
        val notify=synchronized(this) {
            if(layout!=null) {
                if(layout.generation<rawGeneration)return false
                if(layout.generation!=rawGeneration){latest.clear();rawGeneration=layout.generation}
            }
            latest[packet.header.optInt("tile")]=Frame(++revision,packet)
            observer
        }
        // Wake the renderer directly. Video must not depend on Compose recomposition.
        notify?.invoke()
        return true
    }
    @Synchronized fun snapshot():Map<Int,Frame> = latest.toMap()
    fun attach(callback:()->Unit) {
        synchronized(this){observer=callback}
        callback()
    }
    @Synchronized fun detach(callback:()->Unit) {if(observer===callback)observer=null}
}
