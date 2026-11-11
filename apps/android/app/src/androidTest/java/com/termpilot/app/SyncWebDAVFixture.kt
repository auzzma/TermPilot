package com.termpilot.app

import java.net.InetAddress
import java.net.ServerSocket
import java.security.MessageDigest
import kotlin.concurrent.thread

/** Loopback-only encrypted object store. Never contacts a real cloud account. */
internal class SyncWebDAVFixture:AutoCloseable {
    private val server=ServerSocket(0,8,InetAddress.getByName("127.0.0.1"))
    val endpoint="http://127.0.0.1:${server.localPort}/objects"
    private val files=sortedMapOf<String,ByteArray>()
    private val worker=thread(name="sync-webdav-fixture",isDaemon=true){
        while(!server.isClosed){
            val socket=try{server.accept()}catch(_:Exception){break}
            socket.use{client->
                client.soTimeout=5000
                val input=client.getInputStream().buffered()
                fun line():String {
                    val bytes=ArrayList<Byte>()
                    while(true){val b=input.read();if(b<0||b==10)break;if(b!=13)bytes.add(b.toByte());check(bytes.size<32000)}
                    return bytes.toByteArray().toString(Charsets.UTF_8)
                }
                val first=line().split(' ')
                val headers=mutableMapOf<String,String>()
                while(true){val row=line();if(row.isEmpty())break;headers[row.substringBefore(':').lowercase()]=row.substringAfter(':').trim()}
                val length=headers["content-length"]?.toInt()?:0
                val body=ByteArray(length)
                var read=0;while(read<length){val n=input.read(body,read,length-read);check(n>0);read+=n}
                val method=first[0];val name=first[1].substringBefore('?').substringAfterLast('/')
                var status=200;var output=byteArrayOf();var etag:String?=null
                fun tag(data:ByteArray)="\""+MessageDigest.getInstance("SHA-256").digest(data).joinToString(""){"%02x".format(it)}+"\""
                when(method){
                    "PROPFIND"->{status=207;output=("<d:multistatus xmlns:d=\"DAV:\">"+files.keys.joinToString(""){"<d:response><d:href>/objects/$it</d:href></d:response>"}+"</d:multistatus>").toByteArray()}
                    "PUT"->{
                        val current=files[name]?.let{tag(it)}
                        if((headers["if-none-match"]=="*"&&current!=null)||(headers["if-match"]!=null&&headers["if-match"]!=current))status=412
                        else{files[name]=body;status=201}
                    }
                    "GET"->{val value=files[name];if(value==null)status=404 else{output=value;etag=tag(value)}}
                    "DELETE"->{files.remove(name);status=204}
                    else->status=405
                }
                val header="HTTP/1.1 $status Fixture\r\nContent-Length: ${output.size}\r\nConnection: close\r\n"+(etag?.let{"ETag: $it\r\n"}?:"")+"\r\n"
                client.getOutputStream().apply{write(header.toByteArray());write(output);flush()}
            }
        }
    }
    override fun close(){server.close();worker.join(6000);check(!worker.isAlive)}
}
