package com.termpilot.app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

@Composable fun SyncInviteView(model:AppModel,profileId:String?,close:()->Unit,saved:suspend()->Unit) {
    val context=LocalContext.current;val scope=rememberCoroutineScope()
    var key by remember{mutableStateOf("")};var code by remember{mutableStateOf("")};var name by remember{mutableStateOf("Android")}
    var preview by remember{mutableStateOf<JSONObject?>(null)};var qr by remember{mutableStateOf<JSONObject?>(null)}
    var selected by remember{mutableStateOf(setOf("configuration"))};var busy by remember{mutableStateOf(false)}
    var installed by remember{mutableStateOf(false)};var error by remember{mutableStateOf("")};var message by remember{mutableStateOf("")}
    var scanning by remember{mutableStateOf(false)}
    val scopeRows=listOf("configuration" to "主机、分组、代理、脚本、笔记和 AI 配置","credentials" to "密码、私钥和凭证秘密","aiSecrets" to "AI API Key 与认证请求头","preferences" to "外观、语言和终端偏好","aiHistory" to "AI 对话历史")
    val permission=rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()){granted->if(granted)scanning=true else error="未获得相机权限，请允许相机访问或粘贴配置码。"}
    fun perform(action:String){busy=true;error="";message="";scope.launch{try{
        val result=model.call(obj("method" to "sync.invite.$action","id" to (profileId?:""),"passphrase" to key,"code" to code,"name" to name,"scopes" to JSONArray(selected.toList()),"confirmed" to true))
        when(action){
            "export"->{code=result.getString("code");qr=result.optJSONObject("qr");key=""}
            "preview"->preview=result
            else->if(result.optBoolean("installed")){
                installed=true;key="";code="";preview=null;saved();model.reload()
                if(result.optBoolean("synced")){
                    message=(if(result.optBoolean("reused"))"已使用已有配置并完成同步，原同步范围已保留。" else "已添加云服务并完成合并同步。")+
                        "\n当前设备已有 ${model.records["hosts"]?.size?:0} 台主机、${model.records["groups"]?.size?:0} 个分组。"
                }else error="云服务配置已保存，但同步尚未完成。本机数据和待上传修改已保留，请返回数据同步页面重试。\n"+result.optString("error")
            }
        }
    }catch(e:Exception){error=e.message?:"无法处理配置码"}finally{busy=false}}}
    FormPage(footer={SyncOperationProgress(model,busy)},onDismissRequest={if(!busy)close()},title={Text(if(profileId==null)"导入云服务" else "添加设备")},confirmButton={TextButton(enabled=!busy,onClick=close){Text(if(installed)"完成" else "关闭")}},text={
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(16.dp)){
            if(!installed){
                Text(if(profileId==null)"先输入原设备使用的同步 Key，再扫描或粘贴加密配置码。Key 不包含在配置码中。" else "输入此同步库当前的 Key，生成加密配置码。新设备使用同一个 Key 扫码或粘贴即可加入。",style=MaterialTheme.typography.bodyMedium)
                if(profileId==null||code.isEmpty())OutlinedTextField(key,{key=it;preview=null},Modifier.fillMaxWidth(),enabled=!busy,label={Text("同步 Key")},placeholder={Text("请输入当前同步 Key")},singleLine=true,visualTransformation=PasswordVisualTransformation())
                if(profileId!=null){
                    if(code.isEmpty())Button(enabled=!busy&&key.length>=12,onClick={perform("export")}){Text("生成配置码")}
                    else{
                        qr?.let{value->val width=value.optInt("width");val modules=value.optString("modules");if(width>0)Canvas(Modifier.fillMaxWidth().aspectRatio(1f).background(Color.White)){
                            val unit=size.minDimension/(width+8);modules.forEachIndexed{i,v->if(v=='1')drawRect(Color.Black,Offset((i%width+4)*unit,(i/width+4)*unit),Size(unit,unit))}
                        }}?:Text("配置较长，请复制配置码后在新设备上粘贴。")
                        Button(onClick={val clip=ClipData.newPlainText("TermPilot 加密配置码",code);clip.description.extras=android.os.PersistableBundle().apply{putBoolean("android.content.extra.IS_SENSITIVE",true)};(context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(clip);message="已复制加密配置码。"}){Text("复制配置码")}
                        Text("配置码包含加密的云服务访问凭证，请仅交给自己的设备。更换 Key 后应重新生成配置码。",style=MaterialTheme.typography.bodySmall)
                    }
                }else{
                    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){
                        OutlinedButton(enabled=!busy&&key.length>=12,onClick={if(context.checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)scanning=true else permission.launch(Manifest.permission.CAMERA)}){Text("扫描二维码")}
                        OutlinedButton(enabled=!busy&&key.length>=12,onClick={val clip=(context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip;code=if(clip!=null&&clip.itemCount>0)clip.getItemAt(0).coerceToText(context).toString().take(24000)else "";preview=null}){Text("粘贴配置码")}
                    }
                    OutlinedTextField(code,{code=it.take(24000);preview=null},Modifier.fillMaxWidth().heightIn(min=110.dp,max=200.dp),enabled=!busy&&key.length>=12,label={Text("加密配置码")},placeholder={Text("TP-SYNC:1:…")})
                    if(preview==null)Button(enabled=!busy&&key.length>=12&&code.isNotBlank(),onClick={perform("preview")}){Text("解析配置码")}
                    preview?.let{p->
                        Text(p.optString("title"),style=MaterialTheme.typography.titleMedium);Text(p.optJSONObject("provider")?.optString("endpoint")?:"",style=MaterialTheme.typography.bodySmall);Text("库 ID："+p.optString("library"),style=MaterialTheme.typography.bodySmall)
                        OutlinedTextField(name,{name=it.take(100)},Modifier.fillMaxWidth(),enabled=!busy,label={Text("当前设备名称")},singleLine=true)
                        Text("合并并同步的数据",style=MaterialTheme.typography.titleMedium)
                        scopeRows.forEach{(id,label)->Row(Modifier.fillMaxWidth()){Checkbox(selected.contains(id),{if(it)selected=selected+id else selected=selected-id},enabled=!busy&&id!="configuration");Text(label,Modifier.padding(top=12.dp))}}
                        Text("导入后自动启用并同步；当前其它配置暂停。已有相同配置将继续使用，保留原同步范围及未上传修改。脚本和笔记中的手写秘密不会被自动过滤。",style=MaterialTheme.typography.bodySmall)
                        Button(enabled=!busy,onClick={perform("import")}){Text("导入并合并同步")}
                    }
                }
            }
            if(error.isNotEmpty())Text(error,color=MaterialTheme.colorScheme.error)
            if(message.isNotEmpty())Text(message)
        }
    })
    if(scanning)SyncQRScanner(model,close={scanning=false},found={code=it;preview=null;scanning=false;message="已识别配置码，点击解析以核对云服务。"})
}

@Composable private fun SyncQRScanner(model:AppModel,close:()->Unit,found:(String)->Unit){
    val scope=rememberCoroutineScope();val lifecycle=LocalLifecycleOwner.current
    var resumed by remember{mutableStateOf(lifecycle.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))}
    var error by remember{mutableStateOf("")};val processing=remember{AtomicBoolean(false)};val accepted=remember{AtomicBoolean(false)}
    DisposableEffect(lifecycle){val observer=LifecycleEventObserver{_,event->if(event==Lifecycle.Event.ON_RESUME)resumed=true else if(event==Lifecycle.Event.ON_PAUSE)resumed=false};lifecycle.lifecycle.addObserver(observer);onDispose{lifecycle.lifecycle.removeObserver(observer)}}
    FormPage(onDismissRequest=close,title={Text("扫描配置二维码")},confirmButton={TextButton(onClick=close){Text("关闭")}},text={Column(verticalArrangement=Arrangement.spacedBy(16.dp)){
        Text("将另一台设备上的配置二维码放入画面中。相机画面只在本机识别。")
        if(resumed)key(resumed){
            val active=remember{AtomicBoolean(true)}
            DisposableEffect(Unit){onDispose{active.set(false)}}
            AndroidView(modifier=Modifier.fillMaxWidth().height(320.dp),factory={context->
                var last=0L
                QRPreview(context,frame={data,width,height->
                    val now=android.os.SystemClock.elapsedRealtime()
                    if(active.get()&&!accepted.get()&&now-last>550&&processing.compareAndSet(false,true)){
                        last=now
                        val pixels=Base64.encodeToString(data.copyOf(width*height),Base64.NO_WRAP)
                        scope.launch{try{
                            val result=model.call(obj("method" to "sync.qr.decode","width" to width,"height" to height,"pixels" to pixels))
                            val code=result.optString("code").takeUnless{it=="null"||it.isEmpty()}
                            if(active.get()&&code!=null&&accepted.compareAndSet(false,true))found(code)
                        }catch(e:Exception){if(active.get())error=e.message?:"无法识别二维码"}finally{processing.set(false)}}
                    }
                },failure={if(active.get())error="无法启动相机，请检查相机权限或返回粘贴配置码。"})
            },onRelease={active.set(false);it.close()})
        }
        if(error.isNotEmpty())Text(error,color=MaterialTheme.colorScheme.error)
    }})
}
