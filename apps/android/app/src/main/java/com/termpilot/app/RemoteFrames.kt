package com.termpilot.app

/** Latest decoded frame per tile, retained across view/EGL recreation. */
internal class RemoteFrames {
    data class Frame(val revision:Long,val packet:Packet)
    private val latest=sortedMapOf<Int,Frame>()
    private var observer:(()->Unit)?=null
    @Volatile var revision=0L
        private set

    fun publish(packet:Packet) {
        val notify=synchronized(this) {
            latest[packet.header.optInt("tile")]=Frame(++revision,packet)
            observer
        }
        // Wake the renderer directly. Video must not depend on Compose recomposition.
        notify?.invoke()
    }
    @Synchronized fun snapshot():Map<Int,Frame> = latest.toMap()
    fun attach(callback:()->Unit) {
        synchronized(this){observer=callback}
        callback()
    }
    @Synchronized fun detach(callback:()->Unit) {if(observer===callback)observer=null}
}
