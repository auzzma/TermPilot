package com.termpilot.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import kotlin.concurrent.thread

/** Bounded PCM playback on an audio thread, independent of Compose rendering. */
class RemoteAudio {
    private val pending=ArrayBlockingQueue<ByteArray>(16)
    @Volatile private var stopped=false
    private var worker:Thread?=null
    @Synchronized fun append(bytes:ByteArray) {
        if(stopped||bytes.isEmpty()||bytes.size>32768||bytes.size%8!=0)return
        if(worker==null)worker=thread(name="TermPilot.audio"){
            var track:AudioTrack?=null
            try{
                track=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
                    .setBufferSizeInBytes(maxOf(15360,AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT))).setTransferMode(AudioTrack.MODE_STREAM).build()
                track.play()
                while(!stopped){val data=pending.take();val values=FloatArray(data.size/4);ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(values);track.write(values,0,values.size,AudioTrack.WRITE_BLOCKING)}
            }catch(_:InterruptedException){}finally{track?.stop();track?.release();pending.clear()}
        }
        if(!pending.offer(bytes)){pending.poll();pending.offer(bytes)}
    }
    @Synchronized fun stop(){stopped=true;pending.clear();worker?.interrupt()}
}
