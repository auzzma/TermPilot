package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

@Composable fun DataSyncSettings(model:AppModel,close:()->Unit){
    val scope=rememberCoroutineScope()
    var metadata by remember{mutableStateOf(JSONObject())};var status by remember{mutableStateOf(JSONObject())}
    var provider by remember{mutableStateOf("webdav")};val fields=remember{mutableStateMapOf<String,String>()}
    var inviteEditor by remember{mutableStateOf<JSONObject?>(null)}
    var profileEditor by remember{mutableStateOf<JSONObject?>(null)}
    var busy by remember{mutableStateOf(false)};var error by remember{mutableStateOf("")};var confirm by remember{mutableStateOf<Pair<String,JSONObject>?>(null)}
    var recycleSearch by remember{mutableStateOf("")};var retentionMenu by remember{mutableStateOf(false)}
    suspend fun load(){metadata=model.call(obj("method" to "sync.describe"));status=model.call(obj("method" to "sync.status"));if(status.optBoolean("configured")){status.optJSONObject("provider")?.let{cloud->provider=cloud.optString("kind","webdav").takeIf{kind->metadata.objects("providers").any{it.optString("id")==kind}}?:"webdav";fields.clear();cloud.keys().forEach{key->if(cloud.opt(key) is String)fields[key]=cloud.getString(key)}}}}
    fun run(request:JSONObject){busy=true;error="";scope.launch{try{model.call(request);if(request.optString("method")=="sync.profile.use")model.call(obj("method" to "sync.run"))}catch(e:Exception){error=e.message?:"同步失败"}finally{try{load();model.reload()}catch(e:Exception){if(error.isEmpty())error=e.message?:"无法读取同步配置"};busy=false}}}
    LaunchedEffect(Unit){try{load()}catch(e:Exception){error=e.message?:"无法读取同步配置"}}
    var oldPassword by remember{mutableStateOf("")};var newPassword by remember{mutableStateOf("")};var repeatPassword by remember{mutableStateOf("")};var currentPassword by remember{mutableStateOf("")}
    var clientsUpdated by remember{mutableStateOf(false)};var passwordRunning by remember{mutableStateOf(false)};var showProgress by remember{mutableStateOf(false)};var editCredentials by remember{mutableStateOf(false)}
    val passwordProgress=status.optJSONObject("passwordChange")?:JSONObject()
    val passwordActive=passwordProgress.optBoolean("active")
    fun resumePassword(){if(passwordRunning)return;passwordRunning=true;error="";scope.launch{try{model.call(obj("method" to "sync.password.resume"));model.reload()}catch(e:Exception){error=e.message?:"修改 Key 未完成"}finally{try{status=model.call(obj("method" to "sync.status"));val p=status.optJSONObject("passwordChange");if(p?.optBoolean("active")!=true&&p?.optString("phase")!="completed")showProgress=false}catch(e:Exception){error=e.message?:"无法读取迁移进度"};passwordRunning=false}}}
    LaunchedEffect(passwordActive){if(passwordActive)showProgress=true}
    LaunchedEffect(showProgress){while(showProgress){try{status=model.call(obj("method" to "sync.status"))}catch(_:Exception){};delay(800)}}
    val selectedProvider=metadata.objects("providers").find{it.optString("id")==provider}
    FormPage(footer={SyncOperationProgress(model,busy)},onDismissRequest={if(!passwordActive&&!passwordRunning&&!busy)close()},title={Text(tr("数据同步"))},confirmButton={TextButton(enabled=!passwordActive&&!passwordRunning&&!busy,onClick=close){Text(tr("完成"))}},text={
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
            Text("各设备使用相同同步库 ID 和 Key。内容在本机加密，离线修改将在下次同步时合并。",style=MaterialTheme.typography.bodyMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
            GroupedSection("云服务配置") {
                Text("可添加多份同类型服务。一次使用一份配置；切换时保留本机数据，并将期间的增删改与选定同步库合并。", Modifier.padding(16.dp), style=MaterialTheme.typography.bodySmall)
                val profiles=status.objects("profiles")
                if(profiles.isEmpty())Text("尚未添加云服务",Modifier.padding(16.dp))
                profiles.forEach { profile ->
                    Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                        Text(profile.optString("title"),style=MaterialTheme.typography.titleMedium)
                        if(profile.optBoolean("active"))Text("正在使用",color=MaterialTheme.colorScheme.primary,style=MaterialTheme.typography.labelMedium)
                        val cloud=profile.optJSONObject("provider")?:JSONObject()
                        Text((metadata.objects("providers").find{it.optString("id")==cloud.optString("kind")}?.optString("name")?:cloud.optString("kind"))+" · "+cloud.optString("bucket",cloud.optString("endpoint")),style=MaterialTheme.typography.bodySmall)
                        Text("库 ID："+profile.optString("library"),style=MaterialTheme.typography.bodySmall)
                        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                            if(!profile.optBoolean("active"))TextButton(enabled=!busy,onClick={confirm="切换到此云服务？本机数据保留，期间的新增、修改和删除将在此同步库中合并。其它配置暂停同步。" to obj("method" to "sync.profile.use","id" to profile.optString("id"),"confirmed" to true)}){Text("使用此配置")}
                            TextButton(enabled=!busy,onClick={inviteEditor=profile}){Text("添加设备")}
                            TextButton(enabled=!busy,onClick={profileEditor=profile}){Text("编辑")}
                            TextButton(enabled=!busy,onClick={confirm="删除此本机配置及其待上传队列？本机主机和云端数据保持不变；删除前会保存本机恢复备份。" to obj("method" to "sync.profile.delete","id" to profile.optString("id"),"confirmed" to true)}){Text("删除",color=MaterialTheme.colorScheme.error)}
                        }
                    }
                    GroupDivider()
                }
                TextButton(enabled=!busy,onClick={profileEditor=JSONObject()},modifier=Modifier.padding(16.dp)){Text("添加云服务")}
                TextButton(enabled=!busy,onClick={inviteEditor=JSONObject()},modifier=Modifier.padding(horizontal=16.dp)){Text("导入云服务")}
            }
            if(status.optBoolean("configured")){
                GroupedSection("当前同步状态"){
                    SettingRow("库 ID",value=status.optString("library"));GroupDivider();SettingRow("当前设备",value=status.optString("name"));GroupDivider()
                    Row(Modifier.fillMaxWidth().padding(16.dp),horizontalArrangement=Arrangement.SpaceBetween){Text("自动同步");Switch(status.optBoolean("auto"),{run(obj("method" to "sync.configure","confirmed" to true,"auto" to it))},enabled=!busy&&!status.optBoolean("providerUnavailable"))}
                    SettingRow("待上传操作",value=status.optInt("pending").toString())
                    Text("上次检查：${status.optJSONObject("lastCheck")?.optString("at")?:"尚未同步"}",Modifier.padding(16.dp),style=MaterialTheme.typography.bodySmall)
                    status.optJSONObject("lastError")?.optString("message")?.takeIf{it.isNotBlank()}?.let{message->
                        Text("上次同步未完成：$message",Modifier.padding(horizontal=16.dp),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodyMedium)
                    }
                    Row(Modifier.padding(16.dp),horizontalArrangement=Arrangement.spacedBy(12.dp)){Button(onClick={run(obj("method" to "sync.run"))},enabled=!busy&&!status.optBoolean("providerUnavailable")){Text("立即同步")};OutlinedButton(onClick={run(obj("method" to "sync.snapshot"))},enabled=!busy){Text("生成完整快照")}}
                }
                GroupedSection("同步 Key"){
                    if(status.optBoolean("passwordRequired"))Text("云端 Key 已更新。输入当前 Key 后，本机离线修改会继续合并。",Modifier.padding(16.dp),color=MaterialTheme.colorScheme.error)
                    OutlinedTextField(currentPassword,{currentPassword=it},Modifier.fillMaxWidth().padding(16.dp),label={Text("当前同步 Key")},placeholder={Text("请输入当前同步 Key")},singleLine=true,visualTransformation=PasswordVisualTransformation())
                    TextButton(enabled=!busy&&currentPassword.isNotEmpty(),onClick={busy=true;error="";val secret=currentPassword;currentPassword="";scope.launch{try{model.call(obj("method" to "sync.password.unlock","passphrase" to secret));model.call(obj("method" to "sync.run"));load();model.reload()}catch(e:Exception){error=e.message?:"解锁失败"}finally{busy=false}}}){Text("解锁并同步")}
                    GroupDivider()
                    Text("修改同步 Key",Modifier.padding(16.dp),style=MaterialTheme.typography.titleMedium)
                    OutlinedTextField(oldPassword,{oldPassword=it},Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp),label={Text("原同步 Key")},placeholder={Text("请输入原同步 Key")},singleLine=true,visualTransformation=PasswordVisualTransformation())
                    OutlinedTextField(newPassword,{newPassword=it},Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp),label={Text("新同步 Key")},placeholder={Text("至少 12 个字符")},singleLine=true,visualTransformation=PasswordVisualTransformation())
                    OutlinedTextField(repeatPassword,{repeatPassword=it},Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp),label={Text("确认新 Key")},placeholder={Text("请再次输入新 Key")},singleLine=true,visualTransformation=PasswordVisualTransformation())
                    Text("先下载全部旧密文，再重新加密并上传，验证后切换。包含增量、历史快照及回收站，也包含已关闭同步范围的云端历史。请预留新旧两份密文和备份的本机空间。原云端密文暂时保留，旧 Key 仍能解密这些历史副本。",Modifier.padding(16.dp),style=MaterialTheme.typography.bodySmall)
                    Row(Modifier.padding(16.dp)){Text("所有参与同步的设备均已升级；完成前保持页面打开",Modifier.weight(1f));Checkbox(clientsUpdated,{clientsUpdated=it})}
                    Button(modifier=Modifier.padding(16.dp),enabled=!busy&&clientsUpdated&&oldPassword.isNotEmpty()&&newPassword.length>=12&&newPassword==repeatPassword&&newPassword!=oldPassword,onClick={
                        busy=true;error="";scope.launch{try{status=model.call(obj("method" to "sync.password.begin","oldPassphrase" to oldPassword,"newPassphrase" to newPassword,"confirmPassphrase" to repeatPassword,"confirmed" to true,"clientsUpdated" to clientsUpdated));load();oldPassword="";newPassword="";repeatPassword="";showProgress=true;resumePassword()}catch(e:Exception){error=e.message?:"无法开始修改 Key"}finally{busy=false}}
                    }){Text("开始修改 Key")}
                }
                GroupedSection("回收站",footer="默认保留 30 天；尚未上传的恢复内容会留在本机。"){
                    Box {SettingRow("保留期限",value=if(status.isNull("retentionDays"))"长期保留" else "${status.optInt("retentionDays",30)} 天",onClick={retentionMenu=true});DropdownMenu(retentionMenu,{retentionMenu=false}){listOf(7,30,90,0).forEach{days->DropdownMenuItem(text={Text(if(days==0)"长期保留" else "$days 天")},onClick={retentionMenu=false;confirm="新期限用于之后的删除；缩短不会提前清理已有保护期限。" to obj("method" to "sync.retention","days" to if(days==0)JSONObject.NULL else days)})}}}
                    OutlinedTextField(recycleSearch,{recycleSearch=it},Modifier.fillMaxWidth().padding(16.dp),label={Text("搜索已删除记录")})
                    val items=status.objects("recycle").filter{recycleSearch.isBlank()||it.optString("label").contains(recycleSearch,true)};if(items.isEmpty())Text("回收站为空",Modifier.padding(16.dp))
                    items.forEach{item->Column(Modifier.padding(16.dp)){
                        Text(item.optString("label"));Text(item.optString("deletedAt"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        Row{TextButton(enabled=!busy,onClick={confirm="恢复为新记录。本机保留的密码可恢复，其它设备缺少的密码需补填，已有数据保持不变。" to obj("method" to "sync.restore","scope" to item.optString("scope"),"ids" to JSONArray().put(item.optString("id")),"actionId" to UUID.randomUUID().toString(),"confirmed" to true)}){Text("恢复")}
                            TextButton(enabled=!busy,onClick={confirm="清理后无法再从回收站恢复；历史云端密文仍保留，不代表物理擦除。" to obj("method" to "sync.purge","scope" to item.optString("scope"),"ids" to JSONArray().put(item.optString("id")),"confirmed" to true)}){Text("清理",color=MaterialTheme.colorScheme.error)}}
                    };GroupDivider()}
                }
                GroupedSection("冲突"){
                    val conflicts=status.objects("conflicts");if(conflicts.isEmpty())Text("没有待处理冲突",Modifier.padding(16.dp))
                    conflicts.forEach{conflict->Column(Modifier.padding(16.dp)){
                        Text(conflict.optString("id"),style=MaterialTheme.typography.titleSmall)
                        if(conflict.optBoolean("deleted")){Text("删除与编辑并发；原记录保持删除，编辑内容已保留。");TextButton(enabled=!busy,onClick={confirm="确认保留删除，并将编辑候选归档到回收站。" to obj("method" to "sync.resolve","scope" to conflict.optString("scope"),"id" to conflict.optString("id"),"keepDeleted" to true)}){Text("确认保留删除")}}
                        else{val candidates=conflict.optJSONObject("fields")?:JSONObject();candidates.keys().asSequence().toList().sorted().forEach{field->val values=candidates.optJSONArray(field)?:JSONArray();if(values.length()>1){Text(field);for(i in 0 until values.length()){val candidate=values.getJSONObject(i);TextButton(enabled=!busy,onClick={run(obj("method" to "sync.resolve","scope" to conflict.optString("scope"),"id" to conflict.optString("id"),"choices" to obj(field to candidate.getJSONObject("dot"))))}){Text("保留：${candidate.opt("value")}",maxLines=3)}}}}}
                    }}
                }
                GroupedSection("完整快照") {
                    val snapshots=status.objects("snapshots")
                    if(snapshots.isEmpty()) Text("尚未生成快照",Modifier.padding(16.dp))
                    snapshots.forEach { snapshot ->
                        SettingRow(snapshot.optString("at"),value=if(snapshot.optBoolean("verified")) "预览恢复" else "等待同步",onClick={
                            if(!busy && snapshot.optBoolean("verified")) {
                                busy=true
                                scope.launch {
                                    try {
                                        val preview=model.call(obj("method" to "sync.snapshot.preview","id" to snapshot.optString("id")))
                                        confirm="恢复 ${preview.optInt("copies")} 条记录为新副本。已开启同步的偏好和 AI 设置将作为新的修改应用。" to obj("method" to "sync.snapshot.restore","id" to snapshot.optString("id"),"confirmed" to true,"actionId" to UUID.randomUUID().toString())
                                    } catch(e:Exception) { error=e.message?:"快照不可用" }
                                    finally { busy=false }
                                }
                            }
                        })
                    }
                }
            }
            if(error.isNotEmpty())Text(error,color=MaterialTheme.colorScheme.error)
        }
    })
    inviteEditor?.let { profile -> SyncInviteView(model,profile.optString("id").takeIf{it.isNotEmpty()},close={inviteEditor=null},saved={load();model.reload()}) }
    profileEditor?.let { profile -> SyncProfileEditor(model,metadata,profile,close={profileEditor=null},saved={load();model.reload()}) }
    if(showProgress){
        val complete=passwordProgress.optString("phase")=="completed"
        val phases=mapOf("preparing" to "准备本机备份","locking" to "等待同步库空闲","synchronizing" to "合并本机待同步修改","downloading" to "下载并校验全部旧密文","reencrypting" to "使用新 Key 重新加密","uploading" to "上传并回读校验新密文","verifying" to "核对完整性","switching" to "切换同步库版本","finishing" to "更新本机同步状态","completed" to "所有数据已完成切换")
        Dialog(onDismissRequest={},properties=DialogProperties(dismissOnBackPress=false,dismissOnClickOutside=false,usePlatformDefaultWidth=false)){
            Surface(Modifier.fillMaxWidth().padding(24.dp).widthIn(max=560.dp),shape=MaterialTheme.shapes.large){
                Column(Modifier.padding(24.dp).verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(18.dp)){
                    Text(if(complete)"同步 Key 已修改" else "正在修改同步 Key",style=MaterialTheme.typography.titleLarge)
                    Text(phases[passwordProgress.optString("phase")]?:"准备迁移")
                    LinearProgressIndicator(progress={passwordProgress.optInt("percent")/100f},modifier=Modifier.fillMaxWidth())
                    Text("${passwordProgress.optInt("percent")}%"+(if(passwordProgress.optInt("total")>0)" · ${passwordProgress.optInt("completed")} / ${passwordProgress.optInt("total")} 个对象" else ""))
                    val message=if(error.isNotEmpty())error else passwordProgress.optString("error","").takeUnless{it=="null"}?:""
                    if(message.isNotEmpty())Text(message,color=MaterialTheme.colorScheme.error)
                    Text(if(complete)"其它设备下次同步时需输入新 Key，未上传的修改会继续合并。" else "请保持应用和此页面打开，完成前无法关闭。断网或意外退出后，请在本设备继续；已完成的步骤会保留。",style=MaterialTheme.typography.bodyMedium)
                    if(complete)Button(onClick={showProgress=false}){Text("完成")}
                    else if(!passwordRunning){
                        if(editCredentials){
                            val rows=selectedProvider?.optJSONArray("fields")?:JSONArray()
                            for(i in 0 until rows.length()){val row=rows.getJSONArray(i);val key=row.getString(0);if(row.getBoolean(2)||key=="username")OutlinedTextField(fields[key]?:"",{fields[key]=it},Modifier.fillMaxWidth(),label={Text(row.getString(1))},singleLine=true,visualTransformation=if(row.getBoolean(2))PasswordVisualTransformation()else VisualTransformation.None)}
                            Row{TextButton(onClick={editCredentials=false}){Text("返回")};TextButton(onClick={scope.launch{try{val config=obj("kind" to provider);selectedFields(metadata,provider).forEach{config.put(it,fields[it]?:"")};model.call(obj("method" to "sync.provider","provider" to config,"confirmed" to true));editCredentials=false;error=""}catch(e:Exception){error=e.message?:"更新认证失败"}}}){Text("保存认证信息")}}
                        }else{Button(onClick={resumePassword()}){Text("继续修改 Key")};TextButton(onClick={editCredentials=true}){Text("更新云端认证")}}
                    }
                }
            }
        }
    }
    confirm?.let{(message,request)->AlertDialog(onDismissRequest={confirm=null},title={Text("确认操作")},text={Text(message)},confirmButton={TextButton(onClick={confirm=null;run(request)}){Text("确认")}},dismissButton={TextButton(onClick={confirm=null}){Text("取消")}})}
}
private fun selectedFields(metadata:JSONObject,provider:String):List<String>{val rows=metadata.objects("providers").find{it.optString("id")==provider}?.optJSONArray("fields")?:JSONArray();return (0 until rows.length()).map{rows.getJSONArray(it).getString(0)}}
