package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

@Composable fun SyncLeaseSettings(minutes:Int,enabled:Boolean,save:(Int)->Unit) {
    var draft by remember(minutes){mutableStateOf(minutes.toString())}
    val value=draft.toIntOrNull()?.takeIf{it in 1..1440}
    Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(draft,{draft=it},Modifier.fillMaxWidth().testTag("sync-lock-timeout"),
            label={Text("锁超时时长（分钟）")},singleLine=true,enabled=enabled,
            keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number))
        Text("1–1440 分钟，默认 60 分钟。同步期间自动续期；超过此时长未续期，其他设备可在同步时接管。修改用于本机此配置的下一次同步。参与同步的设备需更新到同一新版客户端。",style=MaterialTheme.typography.bodySmall)
        TextButton(onClick={value?.let(save)},enabled=enabled&&value!=null&&value!=minutes,modifier=Modifier.testTag("sync-lock-timeout-save")){Text("保存超时时长")}
    }
}

@Composable fun SyncHistorySettings(count:Int,pending:Int?,enabled:Boolean,save:(Int)->Unit) {
    var draft by remember(count,pending){mutableStateOf((pending?:count).toString())}
    val value=draft.toIntOrNull()?.takeIf{it in 1..100}
    Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(draft,{draft=it},Modifier.fillMaxWidth().testTag("sync-history-count"),
            label={Text("历史版本保留数量")},singleLine=true,enabled=enabled,
            keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Number))
        Text("1–100 份，默认 10 份，不包含当前版本。每个版本是独立完整的加密 TPS。设置在下次成功同步后对整个同步库生效，过期历史延迟清理。",style=MaterialTheme.typography.bodySmall)
        if(pending!=null) Text("待同步设置：${pending} 份",style=MaterialTheme.typography.bodySmall)
        TextButton(onClick={value?.let(save)},enabled=enabled&&value!=null&&value!=(pending?:count),modifier=Modifier.testTag("sync-history-count-save")){Text("保存历史数量")}
    }
}
