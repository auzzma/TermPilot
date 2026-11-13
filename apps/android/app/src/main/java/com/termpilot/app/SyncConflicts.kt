package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

@Composable fun SyncConflicts(conflicts:List<JSONObject>,enabled:Boolean,request:suspend(JSONObject)->JSONObject,confirm:(String,JSONObject)->Unit) {
    var search by remember{mutableStateOf("")}
    Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
        if(conflicts.isEmpty()) Text("没有待处理冲突") else {
            Text("${conflicts.size} 条记录需要确认。比较版本并保存选择，结果会同步到其他设备。",style=MaterialTheme.typography.bodySmall)
            OutlinedTextField(search,{search=it},Modifier.fillMaxWidth(),label={Text("搜索名称、地址或冲突字段")},singleLine=true)
            conflicts.filter{c->search.isBlank()||(listOf(c.optString("title"),c.optString("subtitle"))+c.objects("details").map{it.optString("label")}).joinToString(" ").contains(search,true)}.forEach{conflict->
                key(conflict.optString("revision")){SyncConflictRecord(conflict,enabled,request,confirm)}
            }
        }
    }
}
@Composable private fun SyncConflictRecord(conflict:JSONObject,enabled:Boolean,request:suspend(JSONObject)->JSONObject,confirm:(String,JSONObject)->Unit) {
    var expanded by remember{mutableStateOf(false)};val choices=remember{mutableStateMapOf<String,JSONObject>()}
    val details=conflict.objects("details");val deleted=conflict.optBoolean("deleted")
    fun command()=obj("method" to "sync.resolve","scope" to conflict.optString("scope"),"id" to conflict.optString("id"),"revision" to conflict.optString("revision"),"confirmed" to true,"choices" to JSONObject().apply{choices.forEach{(k,v)->put(k,v)}})
    OutlinedCard(Modifier.fillMaxWidth()) {Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
        TextButton(onClick={expanded=!expanded},modifier=Modifier.fillMaxWidth()){Column(Modifier.fillMaxWidth()){
            Text(conflict.optString("title"),style=MaterialTheme.typography.titleMedium)
            Text(if(deleted)"删除与编辑冲突" else details.joinToString("、"){it.optString("label")},style=MaterialTheme.typography.bodySmall)
        }}
        if(expanded){
            Text(conflict.optString("subtitle"))
            if(deleted){Text("有设备删除了记录，同时另一个版本仍有修改。原记录目前保持删除；需要恢复时可在回收站恢复为副本。")
                conflict.objects("deletions").forEach{Text("删除来源：${it.optString("name")} · ${it.optString("at","时间未记录")}",style=MaterialTheme.typography.bodySmall)}}
            details.forEach{field->val key=field.optString("key")
                Text(field.optString("label"),style=MaterialTheme.typography.titleSmall)
                Text(field.optString("hint"),style=MaterialTheme.typography.bodySmall)
                field.objects("candidates").forEachIndexed{i,candidate->val dot=candidate.getJSONObject("dot");val selected=choices[key]?.toString()==dot.toString()
                    SyncConflictCandidate(conflict,key,candidate,i+1,selected,enabled,request){choices[key]=dot}
                };HorizontalDivider()
            }
            if(deleted)TextButton(enabled=enabled,onClick={confirm("确认保留删除？编辑内容会保留在同步历史和回收站中。",command().put("keepDeleted",true))}){Text("保留删除")}
            else Button(enabled=enabled&&details.isNotEmpty()&&details.all{choices.containsKey(it.optString("key"))},modifier=Modifier.testTag("sync-conflict-save"),onClick={confirm("将所选版本用于“${conflict.optString("title") }”的 ${details.size} 个冲突字段；其他字段保持不变。",command())}){Text("保存冲突选择")}
            Text("记录 ID：${conflict.optString("id")}",style=MaterialTheme.typography.labelSmall)
        }
    }}
}
@Composable private fun SyncConflictCandidate(conflict:JSONObject,field:String,candidate:JSONObject,number:Int,selected:Boolean,enabled:Boolean,request:suspend(JSONObject)->JSONObject,select:()->Unit){
    var revealed by remember{mutableStateOf<String?>(null)};var error by remember{mutableStateOf("")};var loading by remember{mutableStateOf(false)};val scope=rememberCoroutineScope()
    var revealEpoch by remember{mutableStateOf(0)}
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle){val observer=androidx.lifecycle.LifecycleEventObserver{_,event->if(event==androidx.lifecycle.Lifecycle.Event.ON_STOP){revealed=null;revealEpoch++}};lifecycle.addObserver(observer);onDispose{lifecycle.removeObserver(observer)}}
    val source=candidate.optJSONObject("source")?:JSONObject()
    Surface(Modifier.fillMaxWidth(),shape=MaterialTheme.shapes.small,color=if(selected)MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerLow){
        Column(Modifier.padding(12.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
            Text("版本 $number · ${source.optString("name","来源未记录")}"+if(source.optBoolean("local"))" · 本设备" else "",style=MaterialTheme.typography.titleSmall)
            Text(source.optString("at").takeUnless{it=="null"||it.isBlank()}?:"修改时间未记录",style=MaterialTheme.typography.bodySmall)
            androidx.compose.foundation.text.selection.SelectionContainer {Text(revealed?:candidate.optString("display"),Modifier.heightIn(max=160.dp).verticalScroll(rememberScrollState()))}
            if(candidate.optBoolean("secret"))TextButton(enabled=enabled&&!loading,onClick={if(revealed!=null)revealed=null else{loading=true;val epoch=revealEpoch;scope.launch{try{
                val shown=request(obj("method" to "sync.conflict.preview","scope" to conflict.optString("scope"),"id" to conflict.optString("id"),"revision" to conflict.optString("revision"),"field" to field,"dot" to candidate.getJSONObject("dot"),"reveal" to true)).optString("display")
                if(epoch==revealEpoch)revealed=shown
            }catch(e:Exception){error=e.message?:"无法查看此版本"}finally{loading=false}}}}){Text(if(revealed==null)"显示敏感内容" else "隐藏内容")}
            if(!conflict.optBoolean("deleted"))TextButton(enabled=enabled,onClick=select){Text(if(selected)"✓ 已选择此版本" else "选择此版本")}
            if(error.isNotBlank())Text(error,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)
        }
    }
}
@Composable fun SyncMaintenanceStatus(status:JSONObject){
    Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)){
        Text("同步成功后自动检查。按设置的数量保留历史完整版本，不包含当前版本；冲突、删除标记和可恢复的回收站内容完整保留。被淘汰的历史及迁移前的旧文件保护 7 天后分批清理。",style=MaterialTheme.typography.bodySmall)
        if(status.has("checkedAt"))Text("上次检查：${DateFormat.getDateTimeInstance().format(Date(status.optLong("checkedAt")*1000))} · 清理 ${status.optInt("deleted")} 个文件",style=MaterialTheme.typography.bodySmall)
        status.optString("message").takeUnless{it=="null"||it.isBlank()}?.let{Text(it,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
    }
}
