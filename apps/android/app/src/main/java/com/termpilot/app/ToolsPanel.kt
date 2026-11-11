package com.termpilot.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONObject

@Composable fun ToolsPanel(model:AppModel,s:Session){
    val selected=s.selectedTool;val scope=rememberCoroutineScope()
    var query by remember{mutableStateOf("")};var error by remember{mutableStateOf<String?>(null)}
    var confirmation by remember{mutableStateOf<JSONObject?>(null)}
    var output by remember{mutableStateOf("")};var showOutput by remember{mutableStateOf(false)}
    var rows by remember{mutableStateOf<List<JSONObject>>(emptyList())}
    var tmuxWindows by remember{mutableStateOf<List<JSONObject>>(emptyList())};var tmuxSession by remember{mutableStateOf("")}
    var busy by remember{mutableStateOf(false)};var sortMemory by remember{mutableStateOf(false)}
    var rename by remember{mutableStateOf<Pair<String,String>?>(null)};var newName by remember{mutableStateOf("")}
    var editing by remember{mutableStateOf<Pair<String,JSONObject>?>(null)}
    val title=mapOf("files" to "文件","monitor" to "概览","processes" to "进程","scripts" to "脚本","tmux" to "tmux","docker" to "Docker","images" to "镜像","forwards" to "端口转发","notes" to "主机笔记","commands" to "命令历史","history" to "连接历史")[selected]?:"工具"
    suspend fun execute(operation:String,value:String="",extra:JSONObject=JSONObject()):String{
        val info=model.files(s,obj("action" to "systemInfo"));val request=obj("method" to "mobile.serverTool","operation" to operation,"value" to value,"platform" to info.optString("platform"));extra.keys().forEach{request.put(it,extra.get(it))}
        val plan=model.call(request)
        if(plan.optBoolean("interactive")){s.activePanel="terminal";model.text(s,plan.optString("command")+"\n");return ""}
        val result=model.exec(s,plan.optString("command"));val text=result.optString("stdout")+result.optString("stderr")
        check(result.optInt("code")==0){text.ifBlank{tr("远端操作失败，请确认工具已安装且账号有权限")}}
        return text
    }
    suspend fun load(page:String){
        when(page){
            "processes"->{val info=model.files(s,obj("action" to "systemInfo"));val result=if(info.optString("platform")=="windows")model.files(s,obj("action" to "systemMonitor","operation" to "processes")).objects("processes")else{val r=model.exec(s,MonitorParser.processCommand);check(r.optInt("code")==0){r.optString("stderr")};MonitorParser.processes(r.optString("stdout"))};if(s.selectedTool==page)rows=result}
            "commands","tmux","docker","images"->{val op=mapOf("commands" to "commandHistory","tmux" to "tmuxList","docker" to "dockerList","images" to "dockerImages").getValue(page);val text=execute(op);if(s.selectedTool==page){output=if(page=="commands")text else "";rows=if(page=="tmux")text.lineSequence().filter{it.isNotBlank()}.map{val c=it.split('\t');obj("name" to c[0],"windows" to c.getOrElse(1){"0"},"attached" to c.getOrElse(2){"0"})}.toList()else if(page=="commands")emptyList()else text.lineSequence().mapNotNull{runCatching{JSONObject(it)}.getOrNull()}.toList()}}
        }
    }
    fun refresh(){scope.launch{busy=true;error=null;try{if(s.connected)load(selected)else error=tr("请先连接服务器")}catch(e:CancellationException){throw e}catch(e:Exception){error=e.localizedMessage}finally{busy=false}}}
    fun run(operation:String,value:String="",extra:JSONObject=JSONObject(),approved:Boolean=false){
        if(!approved&&operation in listOf("dockerRemove","dockerKill","dockerStop","dockerPrune","dockerImageRemove","tmuxKill","processStop")){confirmation=obj("operation" to operation,"value" to value,"extra" to extra);return}
        scope.launch{busy=true;error=null;try{val result=execute(operation,value,extra)
            if(s.selectedTool!=selected)return@launch
            if(operation=="tmuxWindows"){tmuxSession=value;tmuxWindows=result.lineSequence().filter{it.isNotBlank()}.map{val c=it.split('\t');obj("index" to c[0],"name" to c.getOrElse(1){""})}.toList()}
            else if(operation in listOf("tmuxPreview","dockerLogs","dockerInspect")){output=result;showOutput=true}
            else load(selected)
        }catch(e:CancellationException){throw e}catch(e:Exception){error=e.localizedMessage}finally{busy=false}}
    }
    LaunchedEffect(selected,s.connected,s.execReady,s.filesReady){query="";rows=emptyList();tmuxWindows=emptyList();output="";error=null;if(selected !in listOf("files","monitor"))refresh()}
    BackHandler{s.activePanel=s.toolsReturnPanel}
    Column(Modifier.fillMaxSize().testTag("tools-page")){
        MobileNavigationHeader(title={Column(horizontalAlignment=Alignment.CenterHorizontally){Text(tr(title));Text(s.label,style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}},onBack={s.activePanel=s.toolsReturnPanel},backTag="tools-back",actions={if(selected !in listOf("files","monitor"))IconButton(onClick={refresh()},enabled=!busy){Icon(Icons.Outlined.Refresh,tr("刷新"))}})
        HorizontalDivider()
        Box(Modifier.weight(1f).fillMaxWidth()){
            when(selected){"files"->FilesPanel(model,s);"monitor"->MonitorAppearance(model){MonitorPanel(model,s)};else->Column{
                MobileSearchField(query,{query=it},tr("搜索"),Modifier.padding(MobileDesign.pageInset))
                if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                error?.let{Text(it,Modifier.padding(12.dp),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
                LazyColumn(contentPadding=PaddingValues(horizontal=MobileDesign.pageInset,vertical=4.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
                    if(selected=="processes"){
                        item{Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){MobileSegments(listOf("cpu" to "CPU ↓","memory" to (tr("内存")+" ↓")),if(sortMemory)"memory"else"cpu",{sortMemory=it=="memory"},modifier=Modifier.weight(1f));Text(trf("{} 个进程",rows.size.toString()),Modifier.align(Alignment.CenterVertically),style=MaterialTheme.typography.labelSmall)}}
                        items(rows.filter{query.isBlank()||it.toString().contains(query,true)}.sortedByDescending{it.optDouble(if(sortMemory)"memPercent" else "cpuPercent",0.0)},key={it.optLong("pid")}){r->MobileToolCard{Column(verticalArrangement=Arrangement.spacedBy(8.dp)){Row(verticalAlignment=Alignment.CenterVertically){Text(r.optString("command").substringAfterLast('/'),Modifier.weight(1f),style=MaterialTheme.typography.titleSmall,maxLines=2);IconButton(onClick={run("processStop",r.optLong("pid").toString())}){Icon(Icons.Outlined.StopCircle,tr("终止"),tint=MaterialTheme.colorScheme.error)}};Text("PID ${r.optLong("pid")} · ${r.optString("user")}",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant);Row{Text("CPU "+monitorPercent(r.metric("cpuPercent")),color=MaterialTheme.colorScheme.primary);Spacer(Modifier.weight(1f));Text("MEM "+monitorPercent(r.metric("memPercent")))};Text(r.optString("command"),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.labelSmall,maxLines=3)}}}
                    }else if(selected in listOf("tmux","docker","images")){
                        item{Row(verticalAlignment=Alignment.CenterVertically){Text(trf("{} 项",rows.size.toString()),Modifier.weight(1f),style=MaterialTheme.typography.labelMedium);if(selected=="tmux")FilledTonalButton(onClick={newName="";rename="tmuxCreate" to ""}){Icon(Icons.Outlined.Add,null);Text(tr("新建"))};if(selected=="images")TextButton(onClick={run("dockerPrune")}){Text(tr("清理未使用镜像"))}}}
                        items(rows.filter{query.isBlank()||it.toString().contains(query,true)}){r->var menu by remember{mutableStateOf(false)};val name=r.optString("name",r.optString("Names",r.optString("Repository")));val id=if(selected=="tmux")name else r.optString("ID")
                            MobileToolCard{Column(verticalArrangement=Arrangement.spacedBy(10.dp)){
                                Row(verticalAlignment=Alignment.CenterVertically){Icon(if(selected=="tmux")Icons.Outlined.GridView else Icons.Outlined.Inventory2,null,tint=MaterialTheme.colorScheme.primary);Spacer(Modifier.width(10.dp));Text(name,Modifier.weight(1f),style=MaterialTheme.typography.titleSmall);Box{IconButton(onClick={menu=true}){Icon(Icons.Outlined.MoreVert,tr("操作"))};DropdownMenu(menu,{menu=false}){
                                    val actions=when(selected){"tmux"->listOf("tmuxWindows" to "窗口","tmuxPreview" to "预览","tmuxSend" to "发送命令","tmuxRename" to "重命名","tmuxKill" to "结束");"docker"->listOf("dockerStart" to "启动","dockerStop" to "停止","dockerRestart" to "重启","dockerPause" to "暂停","dockerResume" to "恢复","dockerLogsFollow" to "跟随日志","dockerRename" to "重命名","dockerKill" to "终止","dockerInspect" to "详情","dockerRemove" to "删除");else->listOf("dockerInspect" to "详情","dockerTag" to "标签","dockerImageRemove" to "删除")}
                                    actions.forEach{(op,label)->DropdownMenuItem(text={Text(tr(label))},onClick={menu=false;if(op in listOf("tmuxSend","tmuxRename","dockerRename","dockerTag")){newName="";rename=op to id}else run(op,id)})}
                                }}}
                                Text(if(selected=="tmux")trf("{} 个窗口 · {} 个连接",r.optString("windows"),r.optString("attached"))else if(selected=="docker")r.optString("Image")else r.optString("Tag")+" · "+r.optString("Size"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                                if(selected=="docker")Text(r.optString("Status"),style=MaterialTheme.typography.labelMedium,color=if(r.optString("State")=="running")androidx.compose.ui.graphics.Color(0xff32b768) else MaterialTheme.colorScheme.onSurfaceVariant)
                                Row{if(selected=="tmux")FilledTonalButton(onClick={run("tmuxAttach",id)}){Text(tr("附着"))};if(selected=="docker"){TextButton(onClick={run("dockerLogs",id)}){Text(tr("日志"))};TextButton(onClick={run("dockerShell",id)}){Text("Shell")}}}
                            }}
                        }
                        if(rows.isEmpty()&&!busy&&error==null)item{Text(tr("暂无数据"),Modifier.padding(20.dp),color=MaterialTheme.colorScheme.onSurfaceVariant)}
                        items(tmuxWindows){w->OutlinedButton(onClick={run("tmuxWindowAttach",tmuxSession,obj("window" to w.optInt("index")))}){Text(trf("附着窗口 {} · {}",w.optString("index"),w.optString("name")))}}
                    }else if(selected=="commands"){
                        items(output.lineSequence().filter{it.isNotBlank()&&(query.isBlank()||it.contains(query,true))}.toList().asReversed()){line->MobileToolCard{SelectionContainer{Text(line,fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall)}}}
                        if(output.isBlank()&&!busy&&error==null)item{Text(tr("暂无数据"),Modifier.padding(20.dp))}
                    }else if(selected in listOf("scripts","forwards","notes","history")){
                        if(selected!="history")item{FilledTonalButton(onClick={editing=selected to JSONObject()}){Icon(Icons.Outlined.Add,null);Text(tr("新增"))}}
                        items((model.records[selected]?:emptyList()).filter{(query.isBlank()||it.toString().contains(query,true))&&(selected !in listOf("notes","history")||it.optString("hostID").isEmpty()||it.optString("hostID")==s.host.optString("id"))}){r->MobileToolCard{Column(verticalArrangement=Arrangement.spacedBy(10.dp)){
                            Row{Text(if(selected=="history")java.text.DateFormat.getDateTimeInstance().format(java.util.Date(((r.optDouble("startedAt")+978307200)*1000).toLong()))else r.optString("title",r.optString("name",r.optString("hostname"))),Modifier.weight(1f),style=MaterialTheme.typography.titleSmall);if(selected!="history")IconButton(onClick={editing=selected to r}){Icon(Icons.Outlined.Edit,tr("编辑"))}}
                            if(selected=="history")Text(tr(if(r.optBoolean("succeeded"))"已连接" else "未成功"),style=MaterialTheme.typography.labelSmall)
                            if(r.optString("body").isNotBlank())Text(r.optString("body"),maxLines=5,style=MaterialTheme.typography.bodySmall,fontFamily=if(selected=="scripts")FontFamily.Monospace else FontFamily.Default)
                            if(selected=="scripts")ScriptActions(model,r,s)
                            if(selected=="forwards"){Text("${r.optString("localHost")}:${r.optInt("localPort")} → ${r.optString("remoteHost")}:${r.optInt("remotePort")}",style=MaterialTheme.typography.bodySmall);Row{TextButton(onClick={model.launch{model.files(s,obj("action" to "forwardStart","rule" to r))}}){Text(tr("启动"))};TextButton(onClick={model.launch{model.files(s,obj("action" to "forwardStop","rule" to r))}}){Text(tr("停止"))}}}
                        }}}
                    }
                }
            }}
        }
        TransferPanel(model,s)
        ToolDock(selected,s.protocol=="ssh"){s.selectedTool=it}
    }
    rename?.let{(operation,value)->AlertDialog(onDismissRequest={rename=null},title={Text(tr(if(operation=="tmuxSend")"发送命令" else "名称"))},text={OutlinedTextField(newName,{newName=it},singleLine=true)},confirmButton={TextButton(onClick={run(operation,if(value.isEmpty())newName else value,obj("name" to newName,"text" to newName));rename=null}){Text(tr("保存"))}},dismissButton={TextButton(onClick={rename=null}){Text(tr("取消"))}})}
    confirmation?.let{pending->AlertDialog(onDismissRequest={confirmation=null},title={Text(tr("确认执行服务器操作"))},text={Text(s.label+"\n"+pending.optString("operation")+" · "+pending.optString("value"))},confirmButton={TextButton(onClick={confirmation=null;run(pending.optString("operation"),pending.optString("value"),pending.getJSONObject("extra"),true)}){Text(tr("执行"))}},dismissButton={TextButton(onClick={confirmation=null}){Text(tr("取消"))}})}
    editing?.let{(collection,record)->RecordDialog(model,collection,record){editing=null}}
    if(showOutput)Dialog(onDismissRequest={showOutput=false},properties=DialogProperties(usePlatformDefaultWidth=false)){Surface(Modifier.fillMaxSize().safeDrawingPadding()){Column{Row(Modifier.padding(8.dp),verticalAlignment=Alignment.CenterVertically){IconButton(onClick={showOutput=false}){Icon(Icons.Outlined.ArrowBack,tr("返回"))};Text(tr("结果"),style=MaterialTheme.typography.titleMedium)};HorizontalDivider();LazyColumn{item{SelectionContainer{Text(output,Modifier.padding(16.dp),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall)}}}}}}
}
