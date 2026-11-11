package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import java.util.UUID

@Composable fun RecordDialog(model:AppModel,collection:String,record:JSONObject,initialProfile:JSONObject?=null,isNew:Boolean=false,dismiss:()->Unit){
    var remoteProfile by remember(record){mutableStateOf(initialProfile?:JSONObject())}
    var saving by remember(record){mutableStateOf(false)}
    var value by remember(record){mutableStateOf(JSONObject(record.toString()).apply{
        initialProfile?.let{profile->profile.keys().forEach{put(it,profile.get(it))}}
        for(key in listOf("credentialID","proxyProfileID","groupID","parentGroupID"))if(isNull(key))put(key,"")
        if(!has("id"))put("id",UUID.randomUUID().toString())
        if(collection=="hosts"){if(!has("connectionKind"))put("connectionKind","ssh");if(!has("port"))put("port",22);if(!has("authentication"))put("authentication","password")}
        if(collection=="credentials"&&!has("kind"))put("kind","password")
        if(collection=="scripts"&&!has("shell"))put("shell","/bin/sh")
        if(collection=="proxies"&&!has("port"))put("port",1080)
        if(collection=="forwards"){if(!has("localHost"))put("localHost","127.0.0.1");if(!has("localPort"))put("localPort",8080);if(!has("remoteHost"))put("remoteHost","127.0.0.1");if(!has("remotePort"))put("remotePort",80)}
        if(collection=="proxies")optJSONObject("configuration")?.let{c->c.keys().forEach{put(it,c.get(it))}}
    })}
    LaunchedEffect(record.optString("id")) {
        if(collection=="hosts"&&!isNew&&record.has("id")&&record.optString("connectionKind","ssh")!="ssh")model.launch{
            val profile=model.call(obj("method" to "vault.get","collection" to "screenSharing","id" to record.optString("id"))).optJSONObject("item")
            if(profile!=null){remoteProfile=profile;val next=JSONObject(value.toString());profile.keys().forEach{next.put(it,profile.get(it))};value=next}
        }
    }
    fun change(key:String,text:String){value=JSONObject(value.toString()).put(key,text)}
    val groupTree=hostGroupTree(model.records["groups"].orEmpty().mapIndexed{i,g->HostGroupInfo(g.optString("id"),g.optString("name"),g.optString("parentGroupID").takeUnless{it=="null"}?:"",g.optInt("sortOrder",i))})
    var confirmDelete by remember { mutableStateOf(false) }
    FormPage(onDismissRequest={if(!saving)dismiss()},editing=true,title={Text(if(record.optBoolean("_quick"))tr("快速连接") else if(collection=="hosts")tr(if(record.has("id")&&!isNew)"编辑主机" else "添加主机") else if(!record.has("id"))tr("新增") else tr("编辑"))},text={Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
        @Composable fun field(label:String,key:String,secret:Boolean=false,lines:Int=1){SettingField(value.optString(key,""),{change(key,it)},label=tr(label),modifier=Modifier.fillMaxWidth(),singleLine=lines==1,minLines=lines,visualTransformation=if(secret)PasswordVisualTransformation()else VisualTransformation.None,textStyle=if(lines>1)MaterialTheme.typography.bodySmall.copy(fontFamily=FontFamily.Monospace)else LocalTextStyle.current)}
        when(collection){
            "hosts"->{
                if(!record.optBoolean("_quick"))GroupedSection("基本信息"){
                    field("名称","label");GroupDivider()
                    Choice(tr("分组"),value.optString("groupID"),listOf("" to tr("未分组"))+hostGroupOptions(groupTree)){change("groupID",it)}
                }
                GroupedSection("连接"){
                    Choice(tr("连接类型"),value.optString("connectionKind","ssh"),listOf("ssh" to "SSH","screenSharing" to tr("远程管理"),"rdp" to "RDP")){type->value=JSONObject(value.toString()).put("connectionKind",type).put("port",if(type=="ssh")22 else if(type=="rdp")3389 else 5900)}
                    GroupDivider();field("IP 地址 / 主机名","hostname");GroupDivider();field("端口","port")
                }
                GroupedSection("认证"){
                    Choice(tr("凭证"),value.optString("credentialID"),listOf("" to tr("手动输入"))+(model.records["credentials"]?:emptyList()).map{it.optString("id") to it.optString("label")}){change("credentialID",it)}
                    if(value.optString("credentialID").isBlank()){GroupDivider();field("用户名","username");GroupDivider();field("密码","password",true)}
                }
                GroupedSection("网络"){
                    Choice(tr("代理"),value.optString("proxyProfileID"),listOf("" to tr("直连"))+(model.records["proxies"]?:emptyList()).map{it.optString("id") to it.optString("label")}){change("proxyProfileID",it);if(it.isNotBlank()&&value.optString("mode")=="highPerformance")change("mode","standardVNC")}
                }
                if(value.optString("connectionKind")=="screenSharing")GroupedSection("显示",footer="高性能使用局域网直连、1080p SDR 单虚拟屏。实际设备的媒体解码能力仍需验收。"){
                    Choice(tr("模式"),value.optString("mode","standardVNC"),listOf("standardVNC" to tr("普通 VNC"))+if(value.optString("proxyProfileID").isBlank())listOf("highPerformance" to tr("Apple 高性能"))else emptyList()){change("mode",it)}
                }
            }
            "groups"->GroupedSection("分组"){
                field("名称","name");GroupDivider()
                val current=value.optString("id")
                fun excluded(nodes:List<HostGroupNode>):Set<String> = nodes.flatMap{if(it.group.id==current)it.descendants()else excluded(it.children)}.toSet()
                Choice(tr("上级分组"),value.optString("parentGroupID"),listOf("" to tr("一级分组"))+hostGroupOptions(groupTree).filter{it.first !in excluded(groupTree)}){change("parentGroupID",it)}
            }
            "credentials"->{
                GroupedSection("基本信息"){field("名称","label");GroupDivider();field("用户名","username")}
                GroupedSection("认证"){
                    Choice(tr("类型"),value.optString("kind","password"),listOf("password" to tr("密码"),"identityKey" to tr("私钥"))){change("kind",it)}
                    GroupDivider();if(value.optString("kind")=="identityKey"){field("私钥","privateKey",lines=7);GroupDivider();field("私钥口令","passphrase",true)}else field("密码","password",true)
                }
            }
            "proxies"->{
                GroupedSection("代理配置"){field("名称","label");GroupDivider();Choice(tr("代理类型"),value.optString("type","socks5"),listOf("socks5" to "SOCKS5","http" to "HTTP CONNECT")){change("type",it)}}
                GroupedSection("连接"){field("主机","host");GroupDivider();field("端口","port")}
                GroupedSection("认证（可选）"){field("用户名","username");GroupDivider();field("密码","password",true)}
            }
            "forwards"->{
                GroupedSection("转发"){field("名称","name");GroupDivider();Choice(tr("类型"),value.optString("kind","local"),listOf("local" to tr("本地"),"remote" to tr("远程"),"dynamic" to tr("动态 SOCKS"))){change("kind",it)}}
                GroupedSection("监听"){field("监听地址","localHost");GroupDivider();field("监听端口","localPort")}
                if(value.optString("kind")!="dynamic")GroupedSection("目标"){field("目标地址","remoteHost");GroupDivider();field("目标端口","remotePort")}
            }
            else->{GroupedSection("基本信息"){field("标题","title");if(collection=="scripts"){GroupDivider();field("解释器","shell")}};GroupedSection("内容"){field("内容","body",lines=14)}}
        }
        if(record.has("id")&&!isNew&&!record.optBoolean("_quick"))GroupedSection{TextButton(onClick={confirmDelete=true},modifier=Modifier.fillMaxWidth()){Text(tr("删除"),color=MaterialTheme.colorScheme.error)}}
    }},confirmButton={TextButton(enabled=!saving,onClick={saving=true;model.launch{try{
        val saved=JSONObject(value.toString())
        for(key in listOf("port","localPort","remotePort"))if(saved.has(key))saved.put(key,saved.optString(key).toIntOrNull()?:0)
        if(collection=="hosts"){
            check(saved.optString("hostname").isNotBlank() && saved.optInt("port") in 1..65535){tr("请输入有效的主机地址和端口")}
            if(saved.optString("label").isBlank())saved.put("label",saved.optString("hostname"))
        }
        for(key in listOf("credentialID","proxyProfileID","groupID","parentGroupID"))if(saved.optString(key).isBlank())saved.put(key,JSONObject.NULL)
        if(record.optBoolean("_quick")){saved.remove("_quick");if(saved.optString("label").isEmpty())saved.put("label",saved.optString("hostname"));model.connect(saved);dismiss();return@launch}
        if(collection=="forwards"){if(saved.optString("kind").isEmpty())saved.put("kind","local");if(saved.optString("localHost").isEmpty())saved.put("localHost","127.0.0.1")}
        if(collection=="proxies")saved.put("configuration",obj("type" to saved.optString("type","socks5"),"host" to saved.optString("host"),"port" to saved.optInt("port",1080),"username" to saved.optString("username"),"password" to saved.optString("password")))
        if(collection=="hosts"&&saved.optString("connectionKind")!="ssh"){
            model.call(obj("method" to "vault.save","collection" to "hosts","item" to saved,"screenSharingProfile" to JSONObject(remoteProfile.toString()).apply{put("hostID",saved.optString("id"));put("mode",if(saved.optString("connectionKind")=="rdp")"rdp" else saved.optString("mode","standardVNC"));put("username",saved.optString("username"));put("password",saved.optString("password"));put("port",saved.optInt("port"));if(!has("audio"))put("audio",true)}));model.reload()
        }else model.save(collection,saved)
        dismiss()
    }finally{saving=false}}}){Text(if(record.optBoolean("_quick"))tr("连接") else tr("保存"))}})
    if(confirmDelete)AlertDialog(onDismissRequest={confirmDelete=false},title={Text(tr("删除"))},text={Text(value.optString("label",value.optString("name",value.optString("title"))))},confirmButton={TextButton(onClick={model.launch{model.delete(collection,record.optString("id"));dismiss()}}){Text(tr("删除"),color=MaterialTheme.colorScheme.error)}},dismissButton={TextButton(onClick={confirmDelete=false}){Text(tr("取消"))}})
}
@Composable fun Choice(label:String,selected:String,options:List<Pair<String,String>>,onChange:(String)->Unit){
    var open by remember{mutableStateOf(false)}
    Box{
        androidx.compose.foundation.layout.Row(Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).clickable{open=true}.padding(horizontal=MobileDesign.rowInset,vertical=12.dp),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically){
            Text(label,Modifier.weight(1f))
            Text(options.find{it.first==selected}?.second ?: options.firstOrNull()?.second ?: selected,Modifier.widthIn(max=190.dp),maxLines=2,color=MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(Icons.Outlined.UnfoldMore,null,Modifier.padding(start=4.dp).size(18.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(open,{open=false}){options.forEach{(key,text)->DropdownMenuItem(text={Text(text)},trailingIcon={if(key==selected)Icon(Icons.Outlined.Check,null,Modifier.size(18.dp),tint=MaterialTheme.colorScheme.primary)},onClick={onChange(key);open=false})}}
    }
}

@Composable fun RecordListDialog(model:AppModel,collection:String,dismiss:()->Unit,edit:(JSONObject)->Unit){
    val titles=mapOf("groups" to tr("分组"),"credentials" to tr("凭证"),"proxies" to tr("代理"),"scripts" to tr("脚本"),"notes" to tr("笔记"),"forwards" to tr("端口转发"))
    FormPage(onDismissRequest=dismiss,title={Text(titles[collection]?:collection)},text={Column(Modifier.verticalScroll(rememberScrollState())){
        val original=model.records[collection].orEmpty()
        val groupPaths=if(collection=="groups")hostGroupOptions(hostGroupTree(original.mapIndexed{i,g->HostGroupInfo(g.optString("id"),g.optString("name"),g.optString("parentGroupID").takeUnless{it=="null"}?:"",g.optInt("sortOrder",i))})).toMap()else emptyMap()
        val records=if(collection=="groups")groupPaths.keys.mapNotNull{id->original.find{it.optString("id")==id}}else original
        if(records.isEmpty())SettingRow("暂无数据",subtitle=tr("点击右上角添加"))
        GroupedSection{records.forEachIndexed{index,record->if(index>0)GroupDivider();Row{
            Box(Modifier.weight(1f)){SettingRow(groupPaths[record.optString("id")]?:record.optString("title",record.optString("label",record.optString("name"))),onClick={edit(record)})}
            if(collection=="scripts")listOf(-1 to "↑",1 to "↓").forEach{(direction,label)->TextButton(enabled=index+direction in records.indices,onClick={model.launch{
                val ids=records.map{it.optString("id")}.toMutableList();val id=ids.removeAt(index);ids.add(index+direction,id)
                model.call(obj("method" to "vault.reorder","collection" to collection,"ids" to org.json.JSONArray(ids)));model.reload()
            }},contentPadding=PaddingValues(4.dp)){Text(tr(label))}}
        }}
        }
    }},confirmButton={TextButton(onClick={edit(JSONObject())}){Text(tr("新增"))}})
}
