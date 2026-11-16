package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONObject
import java.util.UUID

internal data class DesktopResolution(val width:Int,val height:Int) {
    val title get()="$width × $height"
    companion object { val presets=listOf(DesktopResolution(1280,720),DesktopResolution(1920,1080),DesktopResolution(2560,1440),DesktopResolution(3840,2160)) }
}

/** One key in flight; a transport acknowledgement is not an authentication result. */
internal class MobileDesktopControls {
    var actionError by mutableStateOf<String?>(null)
    var loginBusy by mutableStateOf(false); private set
    var loginMessage by mutableStateOf("请先点选远端密码输入框；将使用当前连接的密码并回车。"); private set
    var resizeBusy by mutableStateOf(false); private set
    var resizeSupported by mutableStateOf(false); private set
    var resizeBlocked by mutableStateOf(false); private set
    var resizeMessage by mutableStateOf("远端未提供分辨率调整能力，请在远端系统设置中修改。"); private set
    var available:()->Boolean={false}
    var send:suspend (JSONObject)->Unit={throw CancellationException()}
    var keyTimeout=5000L
    var resizeTimeout=15000L
    private var cancelled=false
    private var pending:Pair<String,CompletableDeferred<Boolean>>?=null
    private var resizeID:String?=null
    private var resizeDeadline:Job?=null
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    fun allows(command:JSONObject):Boolean=when(command.optString("kind")){
        "release"->true
        "credentialKey"->!cancelled&&available()&&pending?.first==command.optString("requestID")
        "resize"->available()&&!resizeBlocked&&resizeID==command.optString("requestID")
        else->false
    }
    fun cancelLogin(){if(loginBusy){cancelled=true;loginMessage="已取消密码输入。";pending?.second?.complete(false)}}
    fun stop(){cancelLogin();resizeDeadline?.cancel();resizeDeadline=null;resizeID=null;resizeBusy=false;resizeSupported=false;resizeBlocked=false}
    fun receive(e:JSONObject){when(e.optString("kind")){
        "credentialKeySent"->if(pending?.first==e.optString("requestID"))pending?.second?.complete(true)
        "vncCapabilities"->{resizeSupported=e.optBoolean("canResize");if(resizeID==null)resizeMessage=if(resizeSupported)"分辨率修改须由远端 VNC 服务确认。" else "当前显示器布局暂不支持调整，请在远端系统设置中修改。"}
        "vncResizeResult"->{if(resizeID==null||resizeID!=e.optString("requestID"))return
            if(e.optBoolean("pending")){resizeMessage="正在等待远端系统应用分辨率…";return}
            resizeDeadline?.cancel();resizeDeadline=null;resizeID=null;resizeBusy=false;resizeBlocked=false
            resizeMessage=if(e.optBoolean("accepted"))"远端已确认修改分辨率。" else if(e.optString("code")=="vncResizeProhibited")"远端服务不允许修改分辨率。" else "远端拒绝了此分辨率，请尝试其他尺寸。"
            if(!e.optBoolean("accepted"))actionError=resizeMessage
        }
    }}
    suspend fun login(password:suspend ()->String){
        if(!available()||loginBusy||resizeBusy)return
        actionError=null;loginBusy=true;cancelled=false;loginMessage="正在输入密码…"
        try{
            val value=password()
            val scalars=value.codePoints().toArray()
            if(value.isEmpty()){loginMessage="没有可用的远程桌面凭证，请修改主机或重新打开快速连接。";actionError=loginMessage;return}
            if(scalars.size>1024||scalars.any{Character.getType(it) in listOf(Character.CONTROL.toInt(),Character.LINE_SEPARATOR.toInt(),Character.PARAGRAPH_SEPARATOR.toInt(),Character.SURROGATE.toInt())}){loginMessage="此密码无法自动输入，请在远端手动输入。";actionError=loginMessage;return}
            if(cancelled||!available()){cancelLogin();return}
            send(obj("kind" to "release"))
            for(key in scalars)if(!step(if(key<=255)key else key or 0x01000000))return
            if(!cancelled&&available()&&step(0xff0d))loginMessage="已输入密码并回车，请查看远端登录结果。"
        }catch(e:Exception){if(!cancelled){loginMessage="连接或凭证不可用，请重新连接后再试。";actionError=loginMessage}}
        finally{
            pending?.second?.complete(false);pending=null
            withContext(NonCancellable){runCatching{send(obj("kind" to "release"))}}
            loginBusy=false
        }
    }
    private suspend fun step(key:Int):Boolean{
        if(cancelled||!available()){cancelLogin();return false}
        currentCoroutineContext().ensureActive()
        val id=UUID.randomUUID().toString();val ack=CompletableDeferred<Boolean>();pending=id to ack
        return try{
            withTimeout(keyTimeout){send(obj("kind" to "credentialKey","key" to key,"requestID" to id));ack.await()}
        }catch(e:TimeoutCancellationException){cancelled=true;loginMessage="密码输入超时，请检查远端输入框后再重试。";actionError=loginMessage;false}
        finally{if(pending?.first==id)pending=null;ack.cancel()}
    }
    suspend fun resizeVNC(value:DesktopResolution){
        if(!available()||!resizeSupported||resizeBlocked||resizeBusy||loginBusy||value !in DesktopResolution.presets)return
        actionError=null
        val id=UUID.randomUUID().toString();resizeID=id;resizeBusy=true;resizeMessage="正在请求修改远端分辨率…"
        resizeDeadline=scope.launch{delay(resizeTimeout);if(resizeID==id){resizeBusy=false;resizeBlocked=true;resizeMessage="远端未确认分辨率，请重连后重试。";actionError=resizeMessage}}
        try{send(obj("kind" to "resize","width" to value.width,"height" to value.height,"requestID" to id))}
        catch(e:Exception){if(resizeID==id){resizeDeadline?.cancel();resizeID=null;resizeBusy=false;resizeMessage="连接不可用，请重连后调整分辨率。";actionError=resizeMessage}}
    }
    suspend fun reconnectResolution(operation:suspend ()->Unit){
        if(!available()||loginBusy||resizeBusy)return
        actionError=null;resizeBusy=true;resizeMessage="正在按所选分辨率重新连接…"
        try{operation()}catch(e:Exception){resizeMessage="重新连接失败，请检查连接后重试。";actionError=resizeMessage}finally{resizeBusy=false}
    }
}

/** Appended to RemoteActionBar; it owns no extra row or explanatory captions. */
@Composable internal fun MobileDesktopActions(s:Session,available:Boolean,login:()->Unit,resize:(DesktopResolution)->Unit){
    val controls=s.desktopControls
    var expanded by remember(s.id){mutableStateOf(false)}
    DisposableEffect(s){onDispose{controls.cancelLogin()}}
    RemoteActionDivider()
    RemoteActionButton(tr("输入密码并登录"),login,Modifier.testTag("remote-login-password"),enabled=available&&!controls.loginBusy&&!controls.resizeBusy)
    if(controls.loginBusy)RemoteActionButton(tr("取消"),{controls.cancelLogin()},Modifier.testTag("remote-login-cancel"))
    Box{
        RemoteActionButton(tr("分辨率"),{expanded=true},Modifier.testTag("remote-resolution"))
        DropdownMenu(expanded,{expanded=false}){
            DropdownMenuItem(text={Text("${s.desktopSize.width} × ${s.desktopSize.height}")},onClick={},enabled=false)
            DesktopResolution.presets.forEach{value->DropdownMenuItem(text={Text(value.title+if(s.desktopSize==value)" ✓" else "")},onClick={expanded=false;resize(value)},enabled=available&&!controls.loginBusy&&!controls.resizeBusy&&(s.highPerformance||(controls.resizeSupported&&!controls.resizeBlocked)))}
        }
    }
    controls.actionError?.let{message->AlertDialog(onDismissRequest={controls.actionError=null},title={Text(tr("操作失败"))},text={Text(tr(message))},confirmButton={TextButton(onClick={controls.actionError=null}){Text(tr("关闭"))}})}
}
