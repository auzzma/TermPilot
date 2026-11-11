package com.termpilot.app

import android.app.Application
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import androidx.compose.runtime.*
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

class Session(val id:Long,val host:JSONObject,val protocol:String,val terminal:String) {
    internal val commandQueue=SessionCommandQueue()
    var status by mutableStateOf("连接中")
    var controlKey by mutableStateOf(false)
    var altKey by mutableStateOf(false)
    var searchTerminal by mutableStateOf(false)
    var connected by mutableStateOf(false)
    var latencyMilliseconds by mutableStateOf<Int?>(null)
    fun receiveLatency(status:String,message:String):Boolean {
        if(protocol!="ssh"||status !in listOf("latency","latency-unavailable"))return false
        latencyMilliseconds=if(status=="latency")parseSSHLatency(message)else null
        return true
    }
    var filesReady by mutableStateOf(false)
    var execReady by mutableStateOf(false)
    var path by mutableStateOf(".")
    var entries by mutableStateOf<List<JSONObject>>(emptyList())
    val transfers = mutableStateMapOf<String,JSONObject>()
    var terminalRevision by mutableLongStateOf(0)
    var snapshot by mutableStateOf(JSONObject())
    val audio=RemoteAudio()
    var ai:Long? = null
    var conversation by mutableStateOf(JSONObject())
    var partial by mutableStateOf("")
    var stats by mutableStateOf(JSONObject())
    var renderedFPS by mutableDoubleStateOf(0.0)
    var renderedFrames by mutableLongStateOf(0)
    var rendererInfo by mutableStateOf("")
    var videoError by mutableStateOf("")
    var mediaDiagnostics by mutableStateOf(JSONObject())
    var lastRenderedAt=0L
    var lastFrameAt=0L
    private val samples=mutableMapOf<String,Pair<Long,Long>>()
    fun transferRate(id:String,bytes:Long):Double{val now=System.nanoTime();val old=samples.put(id,now to bytes)?:return 0.0;return maxOf(0,bytes-old.second)/maxOf(.01,(now-old.first)/1e9)}
    internal val frames = RemoteFrames()
    val frameRevision get()=frames.revision
    val downloads = mutableStateListOf<File>()
    var remoteFiles by mutableStateOf<List<String>>(emptyList())
    var remoteClipboard by mutableStateOf("")
    var activePanel by mutableStateOf("terminal")
    var selectedTool by mutableStateOf("monitor")
    var toolsReturnPanel = "terminal"
    var localDrag = false
    val remoteDownloads = mutableMapOf<String,File>()
    var historyStarted=System.currentTimeMillis()/1000.0-978307200.0
    var historySucceeded=false
    var touchpad by mutableStateOf(false)
    // Session-local, without recomposing the whole workspace on every pointer move.
    internal var remoteCursor:RemoteCursorPosition?=null
    var dragLocked by mutableStateOf(false)
    var audioEnabled by mutableStateOf(true)
    val aiScope:String get()="host:"+host.optString("id",host.optString("hostname")+":"+host.optString("username"))
    val label:String get()=host.optString("label",host.optString("hostname"))
}
data class Prompt(val session:Long,val event:JSONObject)
class AppModel(app:Application):AndroidViewModel(app) {
    var runtime:MobileRuntime?=null; private set
    val records=mutableStateMapOf<String,List<JSONObject>>()
    val sessions=mutableStateListOf<Session>()
    val incomingFiles=mutableStateListOf<Uri>()
    var selected by mutableStateOf<Long?>(null)
    var error by mutableStateOf<String?>(null)
    var prompt by mutableStateOf<Prompt?>(null)
    var settings by mutableStateOf(JSONObject())
    var transferHistory by mutableStateOf<List<JSONObject>>(emptyList())
    var ready by mutableStateOf(false)
    var language by mutableStateOf(app.getSharedPreferences("TermPilot",0).getString("language","zh-Hans")?:"zh-Hans")
    fun chooseLanguage(value:String){launch{call(obj("method" to "sync.preferences","values" to obj("language" to value)));MobileLanguage.selection=value;language=value;getApplication<Application>().getSharedPreferences("TermPilot",0).edit().putString("language",value).apply()}}
    var keyOrder by mutableStateOf(app.getSharedPreferences("TermPilot",0).getString("keyOrder",TerminalKey.defaultOrder) ?: TerminalKey.defaultOrder)
    fun setKeys(value:String){keyOrder=value;getApplication<Application>().getSharedPreferences("TermPilot",0).edit().putString("keyOrder",value).apply()}
    var theme by mutableStateOf(app.getSharedPreferences("TermPilot",0).getString("theme","dark") ?: "dark")
    var videoCodec by mutableStateOf(if(app.getSharedPreferences("TermPilot",0).getString("videoCodec","h264")=="h265") "h265" else "h264")
    var fps by mutableIntStateOf(app.getSharedPreferences("TermPilot",0).getInt("fps",60))
    var fontSize by mutableFloatStateOf(app.getSharedPreferences("TermPilot",0).getFloat("fontSize",14f))
    fun setTerminalFont(value:Float){launch{call(obj("method" to "sync.preferences","values" to obj("fontSize" to value.coerceIn(10f,28f))));fontSize=value.coerceIn(10f,28f);getApplication<Application>().getSharedPreferences("TermPilot",0).edit().putFloat("fontSize",fontSize).apply()}}
    var isForeground=true
    fun foreground(active:Boolean){isForeground=active;sessions.filter{it.protocol!="ssh"}.forEach{s->if(!active)s.audio.stop();launch{if(!active)send(s.id,obj("kind" to "release"));if(s.protocol=="rdp")send(s.id,obj("kind" to "clipboardActive","active" to (active&&s.id==selected&&s.audioEnabled)));send(s.id,obj("kind" to "audio","enabled" to (active&&s.id==selected&&s.audioEnabled)))}}}
    val current:Session? get()=sessions.find{it.id==selected}
    internal val remoteTasksStarting=mutableSetOf<String>()
    internal val backgroundTransfers=mutableMapOf<String,TransferBackground.Work>()
    var settingsSession:Session?=null
    suspend fun openAISettings():Session{val s=settingsSession?:Session(0,obj("id" to "settings","label" to "AI 设置"),"settings","").also{settingsSession=it};openAI(s);return s}
    private val pending=mutableMapOf<String,CompletableDeferred<JSONObject>>()
    private val prompts=ArrayDeque<Prompt>()
    init { launch {
        runtime=withContext(Dispatchers.IO){MobileRuntime(app)}
        call(obj("method" to "sync.preferences","initial" to true,"values" to obj("theme" to theme,"language" to language,"fontSize" to fontSize,"fps" to fps,"videoCodec" to videoCodec)))
        reload();transferHistory=call(obj("method" to "mobile.transfers","recover" to true)).objects("items");ready=true
        viewModelScope.launch {while(isActive){if(isForeground){runCatching{call(obj("method" to "sync.tick"))}.getOrNull()?.let{if(!it.optBoolean("skipped"))runCatching{reload()}}};kotlinx.coroutines.delay(5000)}}
        viewModelScope.launch { receiveMobileEvents({runtime?.poll()},{receive(it)}){error=it.message} }
    } }
    fun launch(block:suspend()->Unit) {viewModelScope.launch{try{block()}catch(e:CancellationException){throw e}catch(e:Exception){error=e.message ?: "操作失败"}}}
    suspend fun call(request:JSONObject):JSONObject {
        val result=runtime?.call(request) ?: error("连接引擎未启动")
        result.optJSONObject("preferences")?.let{p->val edit=getApplication<Application>().getSharedPreferences("TermPilot",0).edit()
          if(p.has("theme")){theme=p.getString("theme");edit.putString("theme",theme)}
          if(p.has("language")){language=p.getString("language");MobileLanguage.selection=language;edit.putString("language",language)}
          if(p.has("videoCodec")){videoCodec=if(p.optString("videoCodec")=="h265") "h265" else "h264";edit.putString("videoCodec",videoCodec)}
          if(p.has("fps")){fps=p.getInt("fps");edit.putInt("fps",fps)}
          if(p.has("fontSize")){fontSize=p.getDouble("fontSize").toFloat();edit.putFloat("fontSize",fontSize)}
          edit.apply()
        };return result
    }
    suspend fun reload(){for(c in listOf("hosts","groups","credentials","proxies","scripts","notes","forwards","history")){records[c]=call(obj("method" to "vault.list","collection" to c)).objects("items")}}
    suspend fun save(collection:String,record:JSONObject){call(obj("method" to "vault.save","collection" to collection,"item" to record));reload()}
    suspend fun delete(collection:String,id:String){call(obj("method" to "vault.delete","collection" to collection,"id" to id));reload()}
    fun chooseVideoCodec(value:String){val codec=if(value=="h265") "h265" else "h264";launch{call(obj("method" to "sync.preferences","values" to obj("videoCodec" to codec)));videoCodec=codec;getApplication<Application>().getSharedPreferences("TermPilot",0).edit().putString("videoCodec",codec).apply()}}
    fun appearance(theme:String=this.theme,fps:Int=this.fps){launch{call(obj("method" to "sync.preferences","values" to obj("theme" to theme,"fps" to fps)));this@AppModel.theme=theme;this.fps=fps;getApplication<Application>().getSharedPreferences("TermPilot",0).edit().putString("theme",theme).putInt("fps",fps).apply();sessions.filter{it.protocol!="ssh"}.forEach{s->launch{send(s.id,obj("kind" to "frameRate","fps" to fps))}}}}
    suspend fun connect(saved:JSONObject){
        val host=call(obj("method" to "resolveConnection","host" to saved,"credentials" to JSONArray(records["credentials"] ?: emptyList<JSONObject>()),"proxyProfiles" to JSONArray(records["proxies"] ?: emptyList<JSONObject>()))).getJSONObject("host")
        val config=JSONObject(host.toString())
        val kind=when(host.optString("connectionKind","ssh")){"screenSharing"->"screen";"rdp"->"rdp";else->"ssh"}
        if(kind!="ssh"){
            val profile=call(obj("method" to "vault.get","collection" to "screenSharing","id" to host.optString("id"))).optJSONObject("item")
            profile?.keys()?.forEach{config.put(it,profile.get(it))}
        }
        if(host.opt("credentialID") is String&&host.optString("credentialID").isNotEmpty()){
            config.put("username",host.optString("username")).put("password",host.opt("password"))
        }
        config.put("host",host.optString("hostname")).put("proxy",host.opt("proxyConfiguration"))
            .put("knownHostsFile",File(runtime!!.directory,"known_hosts").path)
            .put("privateKey",host.opt("identityKey")).put("sessionID",UUID.randomUUID().toString().uppercase())
            .put("lockDirectory",File(runtime!!.directory,"screen-lock").path).put("frameRate",fps).put("videoCodec",videoCodec).put("audio",true).put("clipboardSync",true).put("mode",config.optString("mode","standardVNC"))
            .put("clipboardDirectory",File(runtime!!.directory,"Transfers").apply{mkdirs()}.path)
        config.put("cacheDirectory",config.optString("clipboardDirectory"))
        val command=if(kind=="ssh")obj("type" to "connect","config" to config,"cols" to 80,"rows" to 24) else config.put("kind","connect")
        val reply=call(obj("method" to "session.open","protocol" to kind,"terminalReplies" to true,"command" to command))
        val session=Session(reply.getLong("session"),config,kind,reply.optString("terminal"))
        sessions.add(session);selected=session.id;recordConnection(session,false)
    }
    suspend fun recordConnection(s:Session,ended:Boolean){
        val hostID=s.host.optString("id").takeIf{id->records["hosts"]?.any{it.optString("id")==id}==true}
        val item=obj("id" to s.host.optString("sessionID"),"hostID" to hostID,"startedAt" to s.historyStarted,"succeeded" to s.historySucceeded,"endedAt" to if(ended)System.currentTimeMillis()/1000.0-978307200.0 else null)
        call(obj("method" to "vault.save","collection" to "history","item" to item))
        records["history"]=call(obj("method" to "vault.list","collection" to "history")).objects("items")
    }
    suspend fun send(session:Long,command:JSONObject)=sendSequence(session,listOf(command))
    internal suspend fun sendSequence(session:Long,commands:List<JSONObject>){
        val dispatch:suspend (JSONObject)->Unit={command->call(obj("method" to "session.send","session" to session,"command" to command));Unit}
        val queue=sessions.firstOrNull{it.id==session}?.commandQueue
        if(queue!=null)queue.send(commands,dispatch)else commands.forEach{dispatch(it)}
    }
    fun text(s:Session,text:String){var value=text;if(s.protocol=="ssh"&&value.length==1&&value[0].code in 32..127){if(s.controlKey){value=(value[0].code and 31).toChar().toString();s.controlKey=false};if(s.altKey){value="\u001b"+value;s.altKey=false}};launch{send(s.id,if(s.protocol=="ssh")obj("type" to "data","data" to Base64.encodeToString(value.toByteArray(),Base64.NO_WRAP)) else obj("kind" to "text","text" to value))}}
    suspend fun reconnect(s:Session){val saved=records["hosts"]?.find{it.optString("id")==s.host.optString("id")}?:s.host;close(s);connect(saved)}
    suspend fun close(s:Session){runCatching{recordConnection(s,true)};endRemoteTransfers(s);s.audio.stop();s.ai?.let{call(obj("method" to "session.close","session" to it))};call(obj("method" to "session.close","session" to s.id));sessions.remove(s);if(selected==s.id)selected=sessions.lastOrNull()?.id}
    suspend fun request(session:Long,command:JSONObject,id:String,timeout:Long=180000):JSONObject{
        val key="$session:$id";val deferred=CompletableDeferred<JSONObject>();pending[key]=deferred
        try{send(session,command);return withTimeout(timeout){deferred.await()}}finally{pending.remove(key)}
    }
    suspend fun files(s:Session,r:JSONObject):JSONObject{check(s.filesReady){"文件通道尚未就绪"};val id=UUID.randomUUID().toString();r.put("id",id);return request(s.id,obj("type" to "sftpRequest","channel" to "files","request" to r),id)}
    suspend fun exec(s:Session,command:String):JSONObject{check(s.execReady){"工具通道尚未就绪"};val id=UUID.randomUUID().toString();return request(s.id,obj("type" to "sftpRequest","channel" to "exec","request" to obj("id" to id,"action" to "exec","command" to command,"timeoutMS" to 120000)),id)}
    suspend fun list(s:Session,path:String=s.path){val resolved=files(s,obj("action" to "realpath","path" to path)).optString("path",path);s.entries=files(s,obj("action" to "list","path" to resolved)).objects("entries").sortedWith(compareBy<JSONObject>{it.optString("kind")!="directory"}.thenBy{it.optString("name")});s.path=resolved}
    suspend fun recordTransfer(item:JSONObject,status:String,error:String="") {
        transferHistory=call(obj("method" to "mobile.transfer.save","item" to JSONObject(item.toString()).put("status",status).put("error",error).put("updated",System.currentTimeMillis()/1000))).objects("items")
    }
    suspend fun retryTransfer(record:JSONObject){
        val s=sessions.firstOrNull{it.host.optString("id")==record.optString("hostID")&&it.connected&&it.protocol=="ssh"}?:error("请先连接这台主机，再恢复传输")
        transfer(s,record.optBoolean("upload"),File(record.getString("localPath")),record.getString("remotePath"),record)
    }
    suspend fun transfer(s:Session,upload:Boolean,local:File,remote:String,restoring:JSONObject=JSONObject()){
        val id=restoring.optString("id",UUID.randomUUID().toString())
        check(s.transfers[id]?.optString("status") !in listOf("传输中","已暂停")){"该任务已在运行"}
        val regular=if(upload)local.isFile else files(s,obj("action" to "stat","path" to remote)).getJSONObject("entry").optString("kind")=="file"
        val resume=if(regular)restoring.optString("resumeDirectory",File(runtime!!.directory,"Transfers/Checkpoints/$id").path)else ""
        s.transfers[id]=obj("id" to id,"name" to local.name,"status" to "传输中","transferred" to 0,"total" to 0,"localPath" to local.path,"remotePath" to remote,"upload" to upload,"resumeDirectory" to resume,"hostID" to s.host.optString("id"),"label" to s.label,"protocol" to "ssh")
        recordTransfer(s.transfers.getValue(id),"active")
        var background:TransferBackground.Work?=null
        try{
            background=TransferBackground.begin(getApplication(),local.name){launch{controlTransfer(s,id,"cancel")}}
            backgroundTransfers[id]=background
            request(s.id,obj("type" to "sftpRequest","channel" to "files","request" to obj("id" to id,"action" to if(upload)"upload" else "download","localPath" to local.path,"remotePath" to remote,"overwrite" to false,"resumeDirectory" to resume)),id,86400000)
            s.transfers[id]=JSONObject(s.transfers[id].toString()).put("status",if(upload)"已完成" else "已下载，待导出")
            recordTransfer(s.transfers.getValue(id),if(upload)"completed" else "downloaded")
            if(!upload)s.downloads.add(local);list(s)
         }catch(e:Exception){val cancelled=s.transfers[id]?.optBoolean("cancelRequested")==true;s.transfers[id]=JSONObject(s.transfers[id].toString()).put("status",if(cancelled)"已取消" else "失败：${e.message}");runCatching{recordTransfer(s.transfers.getValue(id),if(cancelled)"cancelled" else "interrupted",if(cancelled)"" else e.message?:"")};throw e}
        finally{backgroundTransfers.remove(id);background?.let{TransferBackground.end(getApplication(),it)}}
    }
    suspend fun importFile(uri:Uri):File=withContext(Dispatchers.IO){
        val resolver=getApplication<Application>().contentResolver
        val name=resolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use{if(it.moveToFirst())it.getString(0)else null} ?: "文件"
        check(name.isNotBlank()&&!name.contains('/')&&name!="."&&name!="..")
        val dir=File(runtime!!.directory,"Transfers/${UUID.randomUUID()}").apply{mkdirs()};val file=File(dir,name)
        try{resolver.openInputStream(uri).use{input->checkNotNull(input){"无法读取所选文件"};file.outputStream().use{out->val buffer=ByteArray(256*1024);while(true){ensureActive();val n=input.read(buffer);if(n<0)break;check(dir.usableSpace>64*1024*1024){"暂存空间不足"};out.write(buffer,0,n)};out.fd.sync()}}}catch(e:Exception){dir.deleteRecursively();throw e}
        file
    }
    suspend fun exportFile(file:File,uri:Uri)=withContext(Dispatchers.IO){getApplication<Application>().contentResolver.openOutputStream(uri,"w").use{output->checkNotNull(output);file.inputStream().use{it.copyTo(output,256*1024)}}}
    private suspend fun receive(packet:Packet){
        val e=packet.header;val id=e.optLong("session");val s=sessions.find{it.id==id||it.ai==id}?:settingsSession?.takeIf{it.ai==id}?:return
        if(e.has("ok")&&e.has("id"))complete(id,e.optString("id"),e)
        when(e.optString("type",e.optString("kind"))){
            "data"->{s.terminalRevision++;s.snapshot=call(obj("method" to "terminal.snapshot","id" to s.terminal));s.ai?.let{ai->send(ai,obj("id" to UUID.randomUUID().toString(),"method" to "terminal.output","params" to obj("sessionId" to s.id.toString(),"data" to e.optString("data"))))}}
            "log"->if(id==s.id&&s.receiveLatency(e.optString("status"),e.optString("message"))){ /* Transient connection metric; never terminal output. */ }
            else if(e.optString("status")=="connected"&&e.optString("channel")=="terminal"){if(!s.connected){s.historySucceeded=true;launch{recordConnection(s,false)}};s.connected=true;s.status="已连接";send(id,obj("type" to "sftpOpen","config" to JSONObject()));send(id,obj("type" to "execOpen","config" to JSONObject()))}
            "sftpReady"->{s.filesReady=true;launch{list(s)}}
            "execReady"->s.execReady=true
            "sftpResponse"->{val r=e.getJSONObject("message");val rid=r.optString("id");if(r.optString("event")=="progress"){backgroundTransfers[rid]?.report(r.optLong("transferred"),r.optLong("total"));s.transfers[rid]?.let{old->s.transfers[rid]=JSONObject(old.toString()).put("total",r.optLong("total")).put("transferred",r.optLong("transferred")).put("rate",s.transferRate(rid,r.optLong("transferred")))}}else complete(id,rid,r)}
            "hostKeyPrompt","credentialPrompt","certificate","approval","form"->{val p=Prompt(id,e);if(prompt==null)prompt=p else prompts.addLast(p)}
            "status"->s.status=e.optString("stage")
            "frame"->{s.lastFrameAt=System.nanoTime();s.frames.publish(packet);if(!s.connected){s.historySucceeded=true;launch{recordConnection(s,false)}};s.connected=true;s.status="已连接"}
            "audio"->if(isForeground&&s.id==selected&&s.audioEnabled)s.audio.append(packet.payload)
            "performance"->{s.stats=e;if(System.nanoTime()-s.lastFrameAt>1_000_000_000L)s.renderedFPS=0.0}
            "mediaDiagnostics"->s.mediaDiagnostics=e
            "conversation"->{s.conversation=e.getJSONObject("conversation");s.partial=""}
            "delta"->s.partial+=e.optString("text")
            "toolRequest"->launch{aiTool(s,e)}
            "fileTransfer"->{noteRemoteTransfer(s,e);val tid=e.optString("id",e.optString("requestID"));s.transfers[tid]=obj("id" to tid,"name" to e.optString("name","文件"),"status" to e.optString("stage"),"transferred" to e.optLong("completedBytes"),"total" to e.optLong("totalBytes"),"rate" to if(e.optString("stage")=="transferring")s.transferRate(tid,e.optLong("completedBytes"))else 0);if(e.optString("stage")=="completed")s.remoteDownloads.remove(tid)?.let{s.downloads.add(it)}}
            "remoteDrag"->{val paths=e.optJSONArray("paths")?:JSONArray();s.remoteFiles=(0 until paths.length()).map{paths.getString(it)}}
            "clipboardChanged"->send(id,obj("kind" to "clipboardFetch","requestID" to UUID.randomUUID().toString()))
            "clipboard"->s.remoteClipboard=e.optString("text",String(packet.payload))
            "clipboardFiles"->{val paths=e.optJSONArray("paths")?:JSONArray(String(packet.payload));for(i in 0 until paths.length())s.downloads.add(File(paths.getString(i)));recordReceivedFiles(s,(0 until paths.length()).map{paths.getString(it)})}
            "error"->error=e.optString("message",e.optString("code","连接失败"))
            "sessionEnded","disconnected","exit"->{launch{recordConnection(s,true)};endRemoteTransfers(s);s.audio.stop();s.connected=false;s.latencyMilliseconds=null;s.status="已断开";pending.filterKeys{it.startsWith("$id:")}.values.forEach{it.completeExceptionally(IllegalStateException("连接已断开，操作不会自动重试"))}}
        }
    }
    private fun complete(session:Long,id:String,response:JSONObject){pending.remove("$session:$id")?.let{if(response.optBoolean("ok"))it.complete(response.optJSONObject("result")?:JSONObject().put("items",response.opt("result")))else it.completeExceptionally(IllegalStateException(response.optString("error","操作失败")))}}
    suspend fun answer(p:Prompt,allow:Boolean,text:String="",fields:JSONObject=JSONObject()){
        val e=p.event
        val command=when(e.optString("type",e.optString("kind"))){
            "hostKeyPrompt"->obj("type" to "hostKeyResponse","promptID" to e.optString("promptID"),"accepted" to allow)
            "credentialPrompt"->obj("type" to "credentialResponse","promptID" to e.optString("promptID"),"value" to if(allow)text else null)
            "form"->obj("id" to UUID.randomUUID().toString(),"method" to "interaction.reply","params" to obj("requestId" to e.optString("requestId"),"value" to obj("cancelled" to !allow,"values" to fields)))
            "certificate"->obj("kind" to "certificateDecision","id" to e.optString("id"),"accept" to allow)
            else->obj("id" to UUID.randomUUID().toString(),"method" to "interaction.reply","params" to obj("requestId" to e.optString("requestId"),"value" to obj("allow" to allow,"remember" to false)))
        };send(p.session,command);prompt=prompts.removeFirstOrNull()
    }
    suspend fun aiCall(s:Session,method:String,params:JSONObject=JSONObject()):JSONObject{val id=UUID.randomUUID().toString();return request(checkNotNull(s.ai),obj("id" to id,"method" to method,"params" to params),id)}
    suspend fun openAI(s:Session){
        if(s.ai==null){val context=obj("sessions" to JSONArray().put(obj("sessionId" to s.id.toString(),"hostId" to s.host.optString("id"),"label" to s.label,"hostname" to s.host.optString("hostname"),"username" to s.host.optString("username"),"connected" to (s.connected&&s.protocol=="ssh"),"scope" to s.aiScope)))
            s.ai=call(obj("method" to "session.open","protocol" to "ai","command" to obj("id" to "init","method" to "initialize","params" to obj("context" to context,"tools" to JSONArray(listOf("terminal_write","terminal_read_context","terminal_execute","terminal_start","terminal_poll","terminal_stop")))))).getLong("session")}
        settings=aiCall(s,"settings.get").optJSONObject("settings")?:JSONObject()
        if(s.protocol=="settings")return
        if(!s.conversation.has("id"))s.conversation=aiCall(s,"conversation.create",obj("scope" to s.aiScope,"agent" to settings.optString("selected")))
    }
    private suspend fun aiTool(s:Session,event:JSONObject){val p=event.getJSONObject("payload");val args=p.getJSONObject("arguments")
        val answer=try{check(s.protocol=="ssh"&&args.optString("sessionId")==s.id.toString()&&s.connected){"AI 目标会话已失效"};val result=when(p.optString("name")){
            "terminal_write"->{send(s.id,obj("type" to "data","data" to Base64.encodeToString(args.optString("text").toByteArray(),Base64.NO_WRAP)));JSONObject()}
            "terminal_read_context"->call(JSONObject(args.toString()).put("method","terminal.context").put("id",s.terminal))
            else->error("当前移动客户端不支持此工具")};obj("ok" to true,"result" to result)
        }catch(e:Exception){obj("ok" to false,"error" to e.message)}
        send(checkNotNull(s.ai),obj("id" to UUID.randomUUID().toString(),"method" to "interaction.reply","params" to obj("requestId" to event.optString("requestId"),"value" to answer)))
    }
    override fun onCleared(){sessions.forEach{it.audio.stop()};runtime?.close();super.onCleared()}
}
