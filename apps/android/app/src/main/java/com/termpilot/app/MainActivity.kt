package com.termpilot.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

class MainActivity:ComponentActivity(){
    val mobileModel:AppModel by viewModels()
    private val dropGrants=mutableListOf<android.view.DragAndDropPermissions>()
    override fun onNewIntent(intent:android.content.Intent){super.onNewIntent(intent);setIntent(intent);receiveSharedIntent(intent)}
    override fun onDestroy(){dropGrants.forEach{it.release()};super.onDestroy()}
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState)
    MobileLanguage.load(this)
    receiveSharedIntent(intent)
    window.decorView.setOnDragListener{_,event->when(event.action){
        android.view.DragEvent.ACTION_DRAG_STARTED->event.clipDescription?.hasMimeType("text/uri-list")==true
        android.view.DragEvent.ACTION_DROP->{requestDragAndDropPermissions(event)?.let{dropGrants.add(it)};queueSharedFiles((0 until event.clipData.itemCount).mapNotNull{event.clipData.getItemAt(it).uri});true}
        else->true
    }}
    setContent{
    val model=mobileModel
    val dark=when(model.theme){"light"->false;"system"->isSystemInDarkTheme();else->true}
    SideEffect{androidx.core.view.WindowCompat.getInsetsController(window,window.decorView).apply{isAppearanceLightStatusBars=!dark;isAppearanceLightNavigationBars=!dark}}
    MobileTheme(dark){Surface(Modifier.fillMaxSize(),color=MaterialTheme.colorScheme.background){key(model.language){TermPilot(model)}}}
}}}
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun TermPilot(model:AppModel){
    var homeTab by remember{mutableStateOf("hosts")}
    val lifecycle=androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle,model){val observer=androidx.lifecycle.LifecycleEventObserver{_,event->when(event){androidx.lifecycle.Lifecycle.Event.ON_START->model.foreground(true);androidx.lifecycle.Lifecycle.Event.ON_STOP->model.foreground(false);else->{}}};lifecycle.addObserver(observer);onDispose{lifecycle.removeObserver(observer)}}
    LaunchedEffect(model.selected){model.foreground(lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED))}
    var keyPreferences by remember{mutableStateOf(false)}
    var globalAI by remember{mutableStateOf<Session?>(null)}
    var backup by remember{mutableStateOf(false)}
    var transfers by remember{mutableStateOf(false)}
    var management by remember{mutableStateOf("")}
    var syncSettings by remember{mutableStateOf(false)}
    var edit by remember{mutableStateOf<Pair<String,JSONObject>?>(null)}
    fun openSettings(collection:String){when(collection){
        "sync"->syncSettings=true
        "ai"->model.launch{globalAI=model.openAISettings()};"keybar"->keyPreferences=true
        "backup"->backup=true;"transfers"->transfers=true;else->management=collection
    }}
    BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding()){
        val wideHome=maxWidth>=MobileDesign.wideBreakpoint
        if(model.current!=null){Workspace(model,model.current!!,Modifier.fillMaxSize()){model.selected=null}}
        else Column(Modifier.fillMaxSize()){
            Box(Modifier.weight(1f)){
                when(homeTab){
                    "settings"->SettingsPanel(model,::openSettings)
                    "sessions"->SessionsHome(model){edit="hosts" to obj("_quick" to true)}
                    else->if(wideHome)Row{
                        Box(Modifier.width(MobileDesign.sidebarWidth)){HostHome(model,{edit="hosts" to it}){management="groups"}}
                        VerticalDivider()
                        Box(Modifier.weight(1f).fillMaxHeight(),contentAlignment=Alignment.Center){Empty(tr("选择主机开始连接"),Icons.Outlined.Terminal)}
                    }else HostHome(model,{edit="hosts" to it}){management="groups"}
                }
            }
            HomeNavigation(homeTab){homeTab=it}
        }
    }
    SharedFilesDialog(model)
    if(keyPreferences)KeyPreferencesDialog(model){keyPreferences=false}
    if(transfers)TransferHistoryDialog(model){transfers=false}
    globalAI?.let{AISettingsDialog(model,it){globalAI=null}}
    if(backup)BackupDialog(model){backup=false}
    if(syncSettings)DataSyncSettings(model){syncSettings=false}
    if(management.isNotEmpty())RecordListDialog(model,management,{management=""}){record->edit=management to record}
    edit?.let{(collection,record)->RecordDialog(model,collection,record){edit=null}}
    model.error?.let{AlertDialog(onDismissRequest={model.error=null},title={Text("TermPilot")},text={Text(it)},confirmButton={TextButton(onClick={model.error=null}){Text(tr("好"))}})}
    model.prompt?.let{prompt->var secret by remember(prompt){mutableStateOf("")};var fields by remember(prompt){mutableStateOf(JSONObject())};AlertDialog(onDismissRequest={},title={Text(tr("需要确认"))},text={Column(Modifier.verticalScroll(rememberScrollState())){if(prompt.event.optString("type")=="form")AgentForm(prompt.event.optJSONObject("payload")?:JSONObject(),fields){fields=it}else Text((prompt.event.optJSONObject("detail")?:prompt.event.optJSONObject("payload")?:prompt.event).toString(2),fontFamily=FontFamily.Monospace);if(prompt.event.optString("type")=="credentialPrompt")OutlinedTextField(secret,{secret=it},label={Text(tr("密码或验证码"))},visualTransformation=PasswordVisualTransformation())}},confirmButton={TextButton(onClick={model.launch{model.answer(prompt,true,secret,fields)}}){Text(tr("允许"))}},dismissButton={TextButton(onClick={model.launch{model.answer(prompt,false)}}){Text(tr("拒绝"))}})}
}
private data class Panel(val key:String,val title:String,val icon:ImageVector)
private val panels=listOf(Panel("terminal","终端",Icons.Outlined.Terminal),Panel("tools","工具",Icons.Outlined.Build),Panel("ai","AI",Icons.Outlined.AutoAwesome))
@Composable private fun Workspace(model:AppModel,session:Session,modifier:Modifier,onBack:()->Unit){
    val tab=session.activePanel
    val keyboardController=LocalSoftwareKeyboardController.current
    val focusManager=LocalFocusManager.current
    if(tab=="tools"){
        BoxWithConstraints(modifier.fillMaxHeight()){
            val toolWidth=(maxWidth*.52f).coerceIn(360.dp,560.dp)
            if(maxWidth>=MobileDesign.wideBreakpoint)Row(Modifier.fillMaxSize()){
                Column(Modifier.weight(1f)){
                    Text(session.label,Modifier.padding(16.dp),style=MaterialTheme.typography.titleMedium)
                    HorizontalDivider();TerminalPanel(model,session,Modifier.weight(1f));HorizontalDivider()
                    PanelTabs(tab){session.activePanel=it}
                }
                VerticalDivider();Box(Modifier.width(toolWidth)){ToolsPanel(model,session)}
            }else ToolsPanel(model,session)
        };return
    }
    Column(modifier.fillMaxHeight()){
        Row(Modifier.fillMaxWidth().heightIn(min=56.dp).padding(horizontal=MobileDesign.pageInset),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){
            IconButton(onClick=onBack,modifier=Modifier.size(40.dp)){Icon(Icons.Outlined.ChevronLeft,tr("主机"),tint=MaterialTheme.colorScheme.primary)}
            Box(Modifier.size(7.dp).background(if(session.connected)MobileDesign.Dark.green else MobileDesign.Dark.orange,androidx.compose.foundation.shape.CircleShape))
            Text(session.label,Modifier.weight(1f),maxLines=1,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,style=MaterialTheme.typography.titleMedium)
            Column(horizontalAlignment=Alignment.End) {
                Text(tr(session.status),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                if(session.protocol=="ssh"&&session.connected)session.latencyMilliseconds?.let { latency ->
                    Text("$latency ms",style=MaterialTheme.typography.labelSmall,fontFamily=androidx.compose.ui.text.font.FontFamily.Monospace,
                        color=if(latency<=150)MobileDesign.Dark.green else if(latency<=400)MobileDesign.Dark.orange else MaterialTheme.colorScheme.error)
                }
            }
            if(!session.connected&&session.status=="已断开")IconButton(onClick={model.launch{model.reconnect(session)}},modifier=Modifier.size(40.dp)){Icon(Icons.Outlined.Refresh,tr("重新连接"))}
            IconButton(onClick={model.launch{model.close(session)}},modifier=Modifier.size(40.dp)){Icon(Icons.Outlined.Close,tr("断开"))}
        }
        HorizontalDivider()
        BoxWithConstraints(Modifier.weight(1f)){
            val panelWidth=(maxWidth*.46f).coerceIn(320.dp,440.dp)
            if(maxWidth>=700.dp&&tab=="ai"){Row{TerminalPanel(model,session,Modifier.weight(1f));VerticalDivider();Box(Modifier.width(panelWidth)){ChatPanel(model,session)}}}
            else if(tab=="terminal")TerminalPanel(model,session,Modifier.fillMaxSize())else PanelContent(model,session,tab)
        }
        if(session.protocol!="ssh")RemoteVideoStats(session)
        TransferPanel(model,session)
        HorizontalDivider();PanelTabs(tab,{keyboardController?.hide();focusManager.clearFocus();if(it=="tools"){session.toolsReturnPanel=tab;if(session.protocol!="ssh")session.selectedTool="files"};session.activePanel=it})
    }
}
@Composable private fun PanelTabs(tab:String,select:(String)->Unit){MobileWorkspaceTabs(panels.map{MobileTab(it.key,it.title,it.icon)},tab,select)}

@Composable private fun TerminalPanel(model:AppModel,s:Session,modifier:Modifier){
    var keyboard by remember(s.id){mutableStateOf(false)}
    var remote by remember(s.id){mutableStateOf<RemoteKeyboardHost?>(null)}
    val context=androidx.compose.ui.platform.LocalContext.current
    fun paste(){
        val clipboard=context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val text=clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()?:return
        if(s.protocol=="ssh")model.text(s,if(s.snapshot.optBoolean("bracketedPaste"))"\u001b[200~$text\u001b[201~" else text)
        else model.launch{model.send(s.id,obj("kind" to "clipboardSend","text" to text,"offerId" to UUID.randomUUID().toString()))}
    }
    if(s.searchTerminal)TerminalSearch(model,s)
    Column(modifier){
        if(s.protocol=="ssh")AndroidView(factory={TerminalCanvas(it,model,s)},update={it.update(s.snapshot)},modifier=Modifier.weight(1f).fillMaxWidth())
        else key(s.id){AndroidView(factory={context->RemoteKeyboardHost(context,RemoteCanvas(context,model,s),{model.text(s,it)},{model.key(s,it)},{keyboard=it}).also{remote=it}},update={(it.surface as? RemoteCanvas)?.updateCursor()},onRelease={it.hideKeyboard()},modifier=Modifier.weight(1f).fillMaxWidth())}
        if(s.protocol=="ssh")Row(Modifier.horizontalScroll(rememberScrollState()).padding(6.dp),horizontalArrangement=Arrangement.spacedBy(6.dp)){
            OutlinedButton(onClick={s.searchTerminal=true}){Text(tr("搜索/选择"))}
            FilterChip(s.controlKey,{s.controlKey=!s.controlKey},label={Text("Ctrl")})
            FilterChip(s.altKey,{s.altKey=!s.altKey},label={Text("Alt")})
            OutlinedButton(onClick=::paste){Text(tr("粘贴"))}
            TerminalKey.ordered(model.keyOrder).forEach{item->
                OutlinedButton(onClick={model.text(s,item.text)},contentPadding=PaddingValues(horizontal=12.dp,vertical=6.dp)){Text(item.name)}
            }
        }else RemoteActionBar(s.touchpad,keyboard,s.dragLocked,s.audioEnabled,TerminalKey.ordered(model.keyOrder),onAction={action->
            when(action){
                RemoteAction.Touchpad->{s.touchpad=!s.touchpad;model.launch{model.send(s.id,obj("kind" to "release"))}}
                RemoteAction.Keyboard->remote?.toggleKeyboard()
                RemoteAction.Paste->paste()
                RemoteAction.Copy->(context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager)
                    .setPrimaryClip(android.content.ClipData.newPlainText("TermPilot",s.remoteClipboard))
                RemoteAction.Drag->{s.dragLocked=!s.dragLocked;if(!s.dragLocked)model.launch{model.send(s.id,obj("kind" to "release"))}}
                RemoteAction.ScrollUp->model.launch{model.send(s.id,obj("kind" to "scroll","dy" to -1))}
                RemoteAction.ScrollDown->model.launch{model.send(s.id,obj("kind" to "scroll","dy" to 1))}
                RemoteAction.SystemKey->model.key(s,0xffeb)
                RemoteAction.Audio->{s.audioEnabled=!s.audioEnabled;model.launch{model.send(s.id,obj("kind" to "audio","enabled" to s.audioEnabled))};if(!s.audioEnabled)s.audio.stop()}
            }
        },onShortcut={model.key(s,it.code,it.modifier)})
    }
}
@Composable private fun PanelContent(model:AppModel,s:Session,tab:String){when(tab){"files"->FilesPanel(model,s);"ai"->ChatPanel(model,s);else->ToolsPanel(model,s)}}
@Composable private fun Empty(text:String,icon:ImageVector){Column(Modifier.fillMaxWidth().padding(32.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(16.dp)){Icon(icon,null,Modifier.size(38.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant);Text(text,color=MaterialTheme.colorScheme.onSurfaceVariant)}}
@Composable fun FilesPanel(model:AppModel,s:Session){
    var fileEdit by remember{mutableStateOf<Pair<String,String>?>(null)}
    var path by remember(s.path){mutableStateOf(s.path)}
    val requestExport=rememberFileExport(model)
    val folderPicker=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()){uri->if(uri!=null)model.launch{val file=model.importFolder(uri);model.transfer(s,true,file,s.path.trimEnd('/')+"/"+file.name)}}
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()){uris->model.launch{val files=uris.map{model.importFile(it)};if(s.protocol=="ssh")files.forEach{model.transfer(s,true,it,s.path.trimEnd('/')+"/"+it.name)}else if(s.protocol=="rdp")model.send(s.id,obj("kind" to "clipboardOffer","offerId" to UUID.randomUUID().toString(),"paths" to JSONArray(files.map{it.path})))
        else {check(s.host.optString("mode")=="highPerformance"){tr("普通 VNC 不支持此文件通道")};model.send(s.id,obj("kind" to "dragEnter","paths" to JSONArray(files.map{it.path})));s.localDrag=true;s.activePanel="terminal"}}}
    Column{
        Row(Modifier.padding(12.dp),verticalAlignment=Alignment.CenterVertically){if(s.protocol=="ssh"){Surface(Modifier.weight(1f),shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surface){SettingField(path,{path=it},label=tr("远端路径"))};IconButton(onClick={model.launch{model.list(s,path)}}){Icon(Icons.Outlined.Refresh,tr("刷新"))};IconButton(onClick={fileEdit="mkdir" to s.path}){Icon(Icons.Outlined.CreateNewFolder,tr("新建文件夹"))};IconButton(onClick={folderPicker.launch(null)}){Icon(Icons.Outlined.DriveFolderUpload,tr("上传文件夹"))}};if(s.protocol=="ssh"||s.protocol=="rdp"||s.host.optString("mode")=="highPerformance")IconButton(onClick={picker.launch(arrayOf("*/*"))}){Icon(Icons.Outlined.Upload,tr("上传"))}}
        if(s.protocol!="ssh"){Text(tr("选择文件后，在远端目标文件夹粘贴。远端复制的文件下载完成后，可以导出到系统文件。"),Modifier.padding(16.dp))}
        LazyColumn{
            if(s.protocol=="ssh")item{TextButton(onClick={model.launch{model.list(s,s.path.substringBeforeLast('/',"/"))}}){Text(tr("上级目录"))}}
            items(s.entries,key={it.optString("name")}){entry->val name=entry.optString("name");var menu by remember{mutableStateOf(false)}
                ListItem(headlineContent={Text(name)},supportingContent={Text("${entry.optLong("size")/1024} KiB")},leadingContent={Icon(if(entry.optString("kind")=="directory")Icons.Outlined.Folder else Icons.Outlined.Description,null)},trailingContent={Box{IconButton(onClick={menu=true}){Icon(Icons.Outlined.MoreVert,tr("操作"))};DropdownMenu(menu,{menu=false}){
                    DropdownMenuItem(text={Text(tr("下载"))},onClick={menu=false;model.launch{val file=File(File(model.runtime!!.directory,"Transfers/${UUID.randomUUID()}").apply{mkdirs()},name);model.transfer(s,false,file,s.path.trimEnd('/')+"/"+name);requestExport(file)}})
                    listOf("rename" to tr("重命名"),"chmod" to tr("权限"),"writeText" to tr("编辑文本"),"delete" to tr("删除")).filter{it.first!="writeText"||entry.optString("kind")=="file"}.forEach{(op,label)->DropdownMenuItem(text={Text(tr(label))},onClick={menu=false;fileEdit=op to (s.path.trimEnd('/')+"/"+name)})}
                }}},modifier=Modifier.clickable{if(entry.optString("kind")=="directory")model.launch{model.list(s,s.path.trimEnd('/')+"/"+name)}})
            }
            if(s.host.optString("mode")=="highPerformance"){
                item{TextButton(onClick={model.launch{model.send(s.id,obj("kind" to "dragRequest"))}}){Text(tr("读取远端拖拽文件"))}}
                items(s.remoteFiles){source->TextButton(onClick={model.launch{
                    val name=source.trimEnd('/').substringAfterLast('/');check(name.isNotBlank()&&name!="."&&name!="..")
                    val file=File(File(model.runtime!!.directory,"Transfers/${UUID.randomUUID()}").apply{mkdirs()},name);val id=UUID.randomUUID().toString();s.remoteDownloads[id]=file
                    model.send(s.id,obj("kind" to "fileDownload","requestID" to id,"source" to source,"destination" to file.path))
                }}){Text(trf("下载 {}",source.substringAfterLast('/')))}}
            }
            items(s.downloads){file->TextButton(onClick={requestExport(file)}){Icon(Icons.Outlined.SaveAlt,null);Text(trf("导出 {}",file.name))}}
        }
    }
    fileEdit?.let{(op,target)->FileEditor(model,s,op,target){fileEdit=null}}
}
@Composable fun TransferPanel(model:AppModel,s:Session){if(s.transfers.isEmpty())return
    var expanded by remember{mutableStateOf(false)}
    Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer).padding(8.dp)){
        TextButton(onClick={expanded=!expanded}){Icon(Icons.Outlined.SwapVert,null);Text(trf("文件传输 · {}",s.transfers.size.toString()))}
        if(expanded)LazyColumn(Modifier.heightIn(max=200.dp)){items(s.transfers.entries.toList(),key={it.key}){(id,t)->Column(Modifier.padding(8.dp)){
            Row(verticalAlignment=Alignment.CenterVertically){Text(t.optString("name"),Modifier.weight(1f),maxLines=1);if(TransferState.active(t.optString("status"))) {
                val paused=TransferState.paused(t.optString("status"))
                IconButton(onClick={model.launch{model.controlTransfer(s,id,if(paused)"resume" else "pause")}}){Icon(if(paused)Icons.Outlined.PlayArrow else Icons.Outlined.Pause,if(paused)tr("恢复") else tr("暂停"))}
                IconButton(onClick={model.launch{model.controlTransfer(s,id,"cancel")}}){Icon(Icons.Outlined.Close,tr("取消"))}
            }else IconButton(onClick={s.transfers.remove(id)}){Icon(Icons.Outlined.Check,tr("移除已结束任务"))}}

            LinearProgressIndicator(progress={(t.optDouble("transferred",0.0)/maxOf(1.0,t.optDouble("total",1.0))).toFloat()},modifier=Modifier.fillMaxWidth())
            Text("${tr(TransferState.label(t.optString("status")))} · ${t.optLong("rate")/1024} KiB/s · ${t.optLong("transferred")/1024} / ${t.optLong("total")/1024} KiB",style=MaterialTheme.typography.labelSmall)
        }}}
    }
}
