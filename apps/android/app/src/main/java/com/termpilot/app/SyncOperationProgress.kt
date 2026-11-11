package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.json.JSONObject

@Composable fun SyncOperationProgress(model:AppModel,busy:Boolean){
    var progress by remember{mutableStateOf(JSONObject())}
    var previousID by remember{mutableStateOf("")}
    LaunchedEffect(busy){
        if(busy)previousID=progress.optString("id")
        while(isActive){
            runCatching{model.call(obj("method" to "sync.progress"))}.onSuccess{progress=it}
            delay(if(busy)250 else 800)
        }
    }
    if(!busy&&progress.length()==0)return
    val current=if(busy&&!progress.optBoolean("active")&&progress.optString("id")==previousID)JSONObject()else progress
    val phase=current.optString("phase","preparing")
    val label=mapOf("preparing" to "准备同步","connecting" to "连接并验证云端","listing" to "读取云端目录",
        "merging" to "合并本机修改","downloading" to "下载并合并云端数据","encrypting" to "加密待上传数据",
        "uploading" to "上传数据","verifying" to "回读校验上传数据","finalizing" to "确认云端提交",
        "applying" to "更新本机数据","completed" to "操作完成","failed" to "同步未完成")[phase]?:"正在处理"
    Surface(color=MaterialTheme.colorScheme.surfaceContainer){
        Column(Modifier.fillMaxWidth().testTag("sync-operation-progress").padding(14.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            Row {Text(label,Modifier.weight(1f),style=MaterialTheme.typography.titleSmall);if(!current.isNull("percent"))Text("${current.optInt("percent")}%")}
            if(current.isNull("percent"))LinearProgressIndicator(Modifier.fillMaxWidth())
            else LinearProgressIndicator(progress={current.optInt("percent").coerceIn(0,100)/100f},modifier=Modifier.fillMaxWidth())
            if(!current.isNull("total")&&phase!="completed")Text("当前阶段：${current.optInt("completed")} / ${current.optInt("total")}",style=MaterialTheme.typography.bodySmall)
            Text("下载 ${formatSyncBytes(current.optLong("downloadedBytes"))} · 上传 ${formatSyncBytes(current.optLong("uploadedBytes"))} · 已校验 ${formatSyncBytes(current.optLong("verifiedBytes"))}",style=MaterialTheme.typography.bodySmall)
            if(current.has("error"))Text(current.optString("error"),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)
            if(phase!="completed"&&phase!="failed")Text("百分比为当前阶段；传输量按已完成的加密分块统计。",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
private fun formatSyncBytes(value:Long):String=when{
    value>=1024*1024->String.format(java.util.Locale.ROOT,"%.1f MiB",value/1048576.0)
    value>=1024->String.format(java.util.Locale.ROOT,"%.1f KiB",value/1024.0)
    else->"$value B"
}
