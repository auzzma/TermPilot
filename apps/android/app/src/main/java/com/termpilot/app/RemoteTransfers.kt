package com.termpilot.app

import android.app.Application
import org.json.JSONObject
import java.io.File
import java.util.UUID

fun AppModel.noteRemoteTransfer(s:Session,e:JSONObject) {
    val id=e.optString("id",e.optString("requestID"));if(id.isEmpty())return
    val key="${s.id}-$id";val stage=e.optString("stage");val finished=stage in listOf("completed","failed","cancelled")
    backgroundTransfers[key]?.report(e.optLong("completedBytes"),e.optLong("totalBytes"))
    if(finished)backgroundTransfers.remove(key)?.let{TransferBackground.end(getApplication(),it)}
    else if(!backgroundTransfers.containsKey(key)&&remoteTasksStarting.add(key))launch{
        try {
            val work=TransferBackground.begin(getApplication(),e.optString("name","文件")){launch{send(s.id,obj("kind" to if(s.protocol=="rdp")"cancelTransfer" else "fileCancel","requestID" to id))}}
            if(!s.connected||s.transfers[id]?.optString("status") in listOf("completed","failed","cancelled"))TransferBackground.end(getApplication(),work)
            else backgroundTransfers[key]=work
        }catch(_:Exception){error="后台传输任务未获系统允许，请保持应用前台完成本次传输"}
        finally{remoteTasksStarting.remove(key)}
    }
    if(s.transfers[id]?.optString("status")!=stage){
        val local=s.remoteDownloads[id]?.path?:""
        val state=when{stage=="completed"->if(local.isEmpty())"completed" else "downloaded";stage=="paused"->"paused";finished->"interrupted";else->"active"}
        val row=obj("id" to key,"hostID" to s.host.optString("id"),"label" to s.label,"protocol" to s.protocol,"name" to e.optString("name","文件"),"localPath" to local,"upload" to (e.optString("direction")=="upload"),"total" to e.optLong("totalBytes"),"transferred" to e.optLong("completedBytes"))
        launch{recordTransfer(row,state,e.optString("error",e.optString("code")))}
    }
}
fun AppModel.recordReceivedFiles(s:Session,paths:List<String>){paths.forEach{path->launch{recordTransfer(obj("id" to UUID.randomUUID().toString(),"hostID" to s.host.optString("id"),"label" to s.label,"protocol" to s.protocol,"name" to File(path).name,"localPath" to path,"upload" to false),"downloaded")}}}
fun AppModel.endRemoteTransfers(s:Session){
    if(s.protocol=="ssh")return
    backgroundTransfers.keys.filter{it.startsWith("${s.id}-")}.forEach{key->backgroundTransfers.remove(key)?.let{TransferBackground.end(getApplication(),it)}}
    s.transfers.forEach{(id,t)->if(t.optString("status") !in listOf("completed","failed","cancelled"))launch{recordTransfer(JSONObject(t.toString()).put("id","${s.id}-$id").put("hostID",s.host.optString("id")).put("label",s.label).put("protocol",s.protocol),"interrupted","会话已断开；请重新选择文件发起传输")}}
}
