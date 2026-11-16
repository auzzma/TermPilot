package com.termpilot.app

import kotlinx.coroutines.CancellationException
import org.json.JSONObject

internal fun AppModel.desktopAvailable(s:Session)=s.protocol=="screen"&&s.connected&&!s.isClosing&&isForeground&&selected==s.id&&s.activePanel=="terminal"&&sessions.contains(s)
internal fun AppModel.bindDesktopControls(s:Session){
    s.desktopControls.available={desktopAvailable(s)}
    s.desktopControls.send={command->
        if(s.isClosing||(command.optString("kind")!="release"&&!desktopAvailable(s)))throw CancellationException()
        sendSequence(s.id,listOf(command),desktopAction=true)
    }
}
internal suspend fun AppModel.freshDesktopConnection(s:Session):Pair<JSONObject,Pair<JSONObject,JSONObject>>{
    val source=if(s.savedHost)call(obj("method" to "vault.get","collection" to "hosts","id" to s.host.optString("id"))).optJSONObject("item")?:error("主机或凭证已变更，请重新连接后再试。") else s.sourceHost
    check((s.host.opt("credentialID") as? String).isNullOrEmpty()||!(source.opt("credentialID") as? String).isNullOrEmpty()){"主机或凭证已变更，请重新连接后再试。"}
    val pair=resolveDesktopConnection(source)
    val (resolved,config)=pair
    check(resolved.optString("connectionKind")=="screenSharing"&&resolved.optString("hostname")==s.host.optString("host",s.host.optString("hostname"))&&resolved.optInt("port",5900)==s.host.optInt("port",5900)&&config.optString("username")==s.host.optString("username")&&config.optString("mode","standardVNC")==s.host.optString("mode","standardVNC")){"主机或凭证已变更，请重新连接后再试。"}
    return source to pair
}
internal suspend fun AppModel.enterDesktopPassword(s:Session){
    s.dragLocked=false
    s.desktopControls.login{freshDesktopConnection(s).second.second.opt("password") as? String ?: ""}
}
internal suspend fun AppModel.resizeDesktop(s:Session,value:DesktopResolution){
    if(value !in DesktopResolution.presets)return
    if(!s.highPerformance){s.desktopControls.resizeVNC(value);return}
    s.desktopControls.reconnectResolution{
        try{
            val (source,pair)=freshDesktopConnection(s)
            if(!desktopAvailable(s))throw CancellationException()
            close(s);connect(source,value,pair)
        }catch(e:Exception){error="重新连接失败，请检查主机及凭证后重试。";throw e}
    }
}
