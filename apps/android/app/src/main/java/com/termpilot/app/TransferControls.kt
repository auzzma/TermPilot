package com.termpilot.app
import org.json.JSONObject

object TransferState {
 fun active(status:String)=status in listOf("传输中","已暂停","transferring","paused","queued","preparing")
 fun paused(status:String)=status in listOf("paused","已暂停")
 fun label(status:String)=mapOf("transferring" to "传输中","paused" to "已暂停","queued" to "等待中","preparing" to "准备中","completed" to "已完成","cancelled" to "已取消","failed" to "失败")[status]?:status
}
suspend fun AppModel.controlTransfer(s:Session,id:String,action:String) {
 val item=s.transfers[id]?:return
 if(!TransferState.active(item.optString("status")))return
 if(s.protocol=="ssh") {
  if(action=="cancel")s.transfers[id]=JSONObject(item.toString()).put("cancelRequested",true)
  files(s,obj("action" to action,"targetID" to id))
  val latest=s.transfers[id]?:return
  if(!TransferState.active(latest.optString("status")))return
  s.transfers[id]=JSONObject(latest.toString()).put("status",when(action){"pause"->"已暂停";"resume"->"传输中";else->"已取消"})
  recordTransfer(s.transfers.getValue(id),when(action){"pause"->"paused";"resume"->"active";else->"cancelled"})
 }else send(s.id,obj("kind" to if(s.protocol=="rdp")action+"Transfer" else when(action){"pause"->"filePause";"resume"->"fileResume";else->"fileCancel"},"requestID" to id))
}
