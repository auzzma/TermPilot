package com.termpilot.app

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import org.json.JSONArray
import java.util.UUID

/** Accept only caller-granted content URIs, then stage copies before releasing grants. */
@Suppress("DEPRECATION")
fun MainActivity.receiveSharedIntent(intent:Intent?) {
    if(intent?.action !in listOf(Intent.ACTION_SEND,Intent.ACTION_SEND_MULTIPLE))return
    val uris=if(intent?.action==Intent.ACTION_SEND_MULTIPLE)intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty() else listOfNotNull(intent?.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
    queueSharedFiles(uris)
}
fun MainActivity.queueSharedFiles(uris:List<Uri>){
    val accepted=uris.distinct().filter{it.scheme=="content"}.take(128)
    mobileModel.incomingFiles.clear();mobileModel.incomingFiles.addAll(accepted)
}
@Composable fun SharedFilesDialog(model:AppModel){
    if(model.incomingFiles.isEmpty())return
    val s=model.current
    var busy by remember{mutableStateOf(false)}
    AlertDialog(onDismissRequest={if(!busy)model.incomingFiles.clear()},title={Text("接收 ${model.incomingFiles.size} 个文件")},text={Column{
        Text(if(s==null)tr("请先关闭此提示并选择目标会话，再从文件应用分享或拖入。") else "目标：${s.label}"+(if(s.protocol=="ssh")"\n上传到 ${s.path}" else if(s.protocol=="rdp")tr("\n加入远程剪贴板后，在目标文件夹粘贴") else tr("\n暂存后点击远端目标位置投放")))
        if(busy)LinearProgressIndicator()
    }},confirmButton={TextButton(enabled=!busy&&s!=null&&s.connected&&(s.protocol=="ssh"||s.protocol=="rdp"||s.host.optString("mode")=="highPerformance"),onClick={model.launch{
        busy=true
        try{
            val target=checkNotNull(s);val files=model.incomingFiles.toList().map{model.importFile(it)};model.incomingFiles.clear()
            if(target.protocol=="ssh")files.forEach{model.transfer(target,true,it,target.path.trimEnd('/')+"/"+it.name)}
            else if(target.protocol=="rdp")model.send(target.id,obj("kind" to "clipboardOffer","offerId" to UUID.randomUUID().toString(),"paths" to JSONArray(files.map{it.path})))
            else {model.send(target.id,obj("kind" to "dragEnter","paths" to JSONArray(files.map{it.path})));target.localDrag=true;target.activePanel="terminal"}
        }finally{busy=false}
    }}){Text(tr("继续"))}},dismissButton={TextButton(enabled=!busy,onClick={model.incomingFiles.clear()}){Text(tr("取消"))}})
}
