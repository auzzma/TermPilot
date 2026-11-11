package com.termpilot.app
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.io.File

@Composable fun TransferHistoryDialog(model:AppModel,dismiss:()->Unit){
 val requestExport=rememberFileExport(model)
 FormPage(onDismissRequest=dismiss,title={Text(tr("传输记录"))},text={LazyColumn{
  if(model.transferHistory.isEmpty())item{Text(tr("暂无传输记录"))}
  items(model.transferHistory,key={it.optString("id")}){r->Column(Modifier.padding(vertical=12.dp)){
   Text(r.optString("name"),style=MaterialTheme.typography.titleSmall)
   Text(r.optString("label")+" · "+(mapOf("active" to tr("传输中"),"paused" to tr("已暂停"),"interrupted" to tr("已中断，等待操作"),"completed" to tr("已完成"),"downloaded" to tr("已下载，待导出"),"cancelled" to tr("已取消"))[r.optString("status")]?:r.optString("status")))
   if(r.optString("error").isNotEmpty())Text(r.optString("error"),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)
   if(r.optString("status")=="interrupted"&&r.optString("protocol")=="ssh")TextButton(onClick={model.launch{model.retryTransfer(r)}}){Text(if(r.optString("resumeDirectory").isEmpty())tr("重新传输") else tr("校验并恢复"))}
   if(r.optString("status")=="downloaded")TextButton(onClick={val file=File(r.optString("localPath"));requestExport(file)}){Text(tr("导出文件"))}
  }}
 }},confirmButton={TextButton(onClick=dismiss){Text(tr("完成"))}})
}
