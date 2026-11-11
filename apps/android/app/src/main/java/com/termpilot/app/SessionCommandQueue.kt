package com.termpilot.app

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/** A chord must finish before another key, text commit or pointer release can interrupt it. */
internal class SessionCommandQueue {
    private val lock=Mutex()
    suspend fun send(commands:List<JSONObject>,dispatch:suspend (JSONObject)->Unit) {
        lock.withLock { commands.forEach { dispatch(it) } }
    }
}

internal fun remoteKeyPress(code:Int,modifier:Int?=null):List<JSONObject> = buildList {
    if(modifier!=null)add(obj("kind" to "key","key" to modifier,"down" to true))
    add(obj("kind" to "key","key" to code,"down" to true))
    add(obj("kind" to "key","key" to code,"down" to false))
    if(modifier!=null)add(obj("kind" to "key","key" to modifier,"down" to false))
}
