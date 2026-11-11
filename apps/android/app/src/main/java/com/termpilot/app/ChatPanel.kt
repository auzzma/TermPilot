package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import org.json.JSONArray
import org.json.JSONObject

@Composable fun ChatPanel(model:AppModel,s:Session){
    var input by remember(s.id){mutableStateOf("")};var configure by remember{mutableStateOf(false)};var history by remember{mutableStateOf<List<JSONObject>?>(null)};var agents by remember{mutableStateOf(false)}
    val messageList=rememberLazyListState()
    LaunchedEffect(s.conversation.objects("messages").size,s.partial){if(messageList.layoutInfo.totalItemsCount>0&&!messageList.canScrollForward)messageList.animateScrollToItem(messageList.layoutInfo.totalItemsCount-1)}
    LaunchedEffect(s.id){model.launch{model.openAI(s)}}
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).testTag("ai-conversation")){
        Row(Modifier.padding(12.dp),verticalAlignment=Alignment.CenterVertically){Icon(Icons.Outlined.AutoAwesome,null);Box(Modifier.weight(1f)){TextButton(onClick={agents=true}){Text(model.settings.objects("providers").find{it.optString("id")==s.conversation.optString("agent")}?.optString("name")?:"TermPilot Agent")};DropdownMenu(agents,{agents=false}){model.settings.objects("providers").forEach{provider->DropdownMenuItem(text={Text(provider.optString("name"))},onClick={agents=false;model.launch{s.conversation=model.aiCall(s,"conversation.draft",obj("conversationId" to s.conversation.optString("id"),"agent" to provider.optString("id")))}})}}};IconButton(onClick={model.launch{history=model.aiCall(s,"conversation.list",obj("scope" to s.aiScope)).objects("items")}}){Icon(Icons.Outlined.History,tr("对话历史"))};IconButton(onClick={model.launch{s.conversation=model.aiCall(s,"conversation.create",obj("scope" to s.aiScope,"agent" to model.settings.optString("selected")))}}){Icon(Icons.Outlined.EditNote,tr("新对话"))};IconButton(onClick={configure=true}){Icon(Icons.Outlined.Settings,tr("AI 设置"))}}
        HorizontalDivider()
        LazyColumn(Modifier.weight(1f),state=messageList,contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(14.dp)){
            val messages=s.conversation.objects("messages")
            if(messages.isEmpty())item{Column(Modifier.fillMaxWidth().padding(vertical=48.dp),horizontalAlignment=Alignment.CenterHorizontally){Icon(Icons.Outlined.AutoAwesome,null,Modifier.size(40.dp));Text(trf("与 {} 对话",s.label),Modifier.padding(16.dp),style=MaterialTheme.typography.titleLarge);Text(tr("询问服务器状态、分析终端输出或获取配置帮助"),textAlign=androidx.compose.ui.text.style.TextAlign.Center,color=MaterialTheme.colorScheme.onSurfaceVariant);if(model.settings.objects("providers").isEmpty())TextButton(onClick={configure=true}){Text(tr("配置 AI"))}}}
            items(messages){message->ChatMessage(message)}
            if(s.partial.isNotEmpty())item{MarkdownView(s.partial)}
        }
        Surface(Modifier.padding(12.dp),shape=RoundedCornerShape(MobileDesign.composerRadius),color=MaterialTheme.colorScheme.surface){
            Row(Modifier.padding(start=12.dp,end=4.dp,top=4.dp,bottom=4.dp),verticalAlignment=Alignment.Bottom){
                androidx.compose.foundation.text.BasicTextField(input,{input=it},Modifier.weight(1f).padding(vertical=10.dp).semantics{contentDescription=trf("发送到 {}",s.label)},maxLines=6,
                    textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),cursorBrush=androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
                    decorationBox={inner->Box{if(input.isEmpty())Text(trf("发送到 {}",s.label),color=MaterialTheme.colorScheme.onSurfaceVariant);inner()}})
                if(s.conversation.optString("status")=="running")IconButton(onClick={model.launch{model.aiCall(s,"turn.stop",obj("conversationId" to s.conversation.optString("id")))}}){Icon(Icons.Outlined.StopCircle,tr("停止"),tint=MaterialTheme.colorScheme.primary)}
                else IconButton(enabled=input.isNotBlank(),onClick={val text=input;input="";model.launch{model.aiCall(s,"turn.start",obj("conversationId" to s.conversation.optString("id"),"text" to text))}}){Icon(Icons.Outlined.ArrowCircleUp,tr("发送"),Modifier.size(28.dp),tint=MaterialTheme.colorScheme.primary.copy(alpha=if(input.isNotBlank())1f else .35f))}
            }
        }

    }
    history?.let{rows->FormPage(onDismissRequest={history=null},title={Text(trf("{} 的对话",s.label))},text={LazyColumn{items(rows){row->Row{TextButton(onClick={model.launch{s.conversation=model.aiCall(s,"conversation.get",obj("conversationId" to row.optString("id")));history=null}},modifier=Modifier.weight(1f)){Text(row.optString("title",tr("对话")))};IconButton(onClick={model.launch{model.aiCall(s,"conversation.delete",obj("conversationId" to row.optString("id")));history=rows.filter{it.optString("id")!=row.optString("id")}}}){Icon(Icons.Outlined.Delete,tr("删除"))}}}}},confirmButton={TextButton(onClick={history=null}){Text(tr("完成"))}})}
    if(configure)AISettingsDialog(model,s){configure=false}
}
@Composable fun ProviderDialog(model:AppModel,s:Session,providerID:String="",dismiss:()->Unit){
    val current=model.settings.objects("providers").find{it.optString("id")==providerID.ifBlank{model.settings.optString("selected")}}
    var id by remember{mutableStateOf(current?.optString("id") ?: java.util.UUID.randomUUID().toString())}
    var name by remember{mutableStateOf(current?.optString("name") ?: "OpenAI")}
    var url by remember{mutableStateOf(current?.optString("baseUrl") ?: "https://api.openai.com/v1")}
    var key by remember{mutableStateOf(current?.optString("apiKey") ?: "")}
    var selected by remember{mutableStateOf(current?.optString("model") ?: "")}
    var protocol by remember{mutableStateOf(current?.optString("protocol") ?: "chat")}
    var models by remember{mutableStateOf<List<Pair<String,String>>>(emptyList())}
    var advanced by remember{mutableStateOf(false)};var deleteConfirmation by remember{mutableStateOf(false)}
    var contextWindow by remember{mutableStateOf(current?.optInt("contextWindow",32768)?.toString()?:"32768")}
    var proxy by remember{mutableStateOf(current?.optString("proxy")?:"")}
    var headers by remember{mutableStateOf((current?.optJSONObject("headers")?:JSONObject()).toString(2))}
    var parameters by remember{mutableStateOf((current?.optJSONObject("parameters")?:JSONObject()).toString(2))}
    var verifyTLS by remember{mutableStateOf(current?.optBoolean("verifyTls",true)?:true)}
    var enabled by remember{mutableStateOf(current?.optBoolean("enabled",true)?:true)}
    fun provider()=JSONObject((model.settings.objects("providers").find{it.optString("id")==id}?:JSONObject()).toString()).apply{val update=obj("id" to id,"name" to name,"kind" to "custom","protocol" to protocol,"baseUrl" to url,"apiKey" to key,"model" to selected,"enabled" to enabled,"verifyTls" to verifyTLS,"contextWindow" to contextWindow.toInt().also{check(it>0)},"proxy" to proxy,"headers" to JSONObject(headers),"parameters" to JSONObject(parameters));update.keys().forEach{put(it,update.get(it))}}
    var loadingModels by remember { mutableStateOf(false) }
    var modelError by remember { mutableStateOf("") }
    FormPage(onDismissRequest=dismiss,editing=true,title={Text(tr(if(providerID=="new")"新增提供商" else "AI 提供商"))},text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
        GroupedSection("基本信息"){
            SettingField(name,{name=it},label=tr("名称"));GroupDivider()
            Choice(tr("协议"),protocol,listOf("chat" to tr("OpenAI 兼容"),"responses" to "Responses","anthropic" to "Anthropic","google" to "Google")){protocol=it;models=emptyList()}
        }
        GroupedSection("服务连接"){
            SettingField(url,{url=it;models=emptyList()},label="Base URL",singleLine=true);GroupDivider()
            SettingField(key,{key=it;models=emptyList()},label="API Key",singleLine=true,visualTransformation=androidx.compose.ui.text.input.PasswordVisualTransformation())
        }
        GroupedSection("模型"){
            SettingField(selected,{selected=it},label=tr("默认模型"),singleLine=true);GroupDivider()
            TextButton(enabled=!loadingModels,onClick={loadingModels=true;modelError="";model.launch{try{val result=model.aiCall(s,"provider.models",obj("provider" to provider()));val a=result.optJSONArray("models")?:result.optJSONArray("items")?:JSONArray();models=(0 until a.length()).map{val v=a.get(it);val n=if(v is JSONObject)v.optString("id")else v.toString();n to n};if(models.isEmpty())modelError=tr("未返回模型，请手动输入模型 ID")}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(e:Exception){modelError=e.localizedMessage?:tr("获取失败")}finally{loadingModels=false}}}){if(loadingModels)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp);Text(tr(if(loadingModels)"正在获取模型…" else "获取模型"),Modifier.padding(horizontal=8.dp))}
            if(modelError.isNotEmpty())Text(modelError,Modifier.padding(14.dp),color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)
            if(models.isNotEmpty())Choice(tr("选择模型"),selected,models){selected=it}
        }
        GroupedSection{
        SettingRow("高级参数",onClick={advanced=!advanced},chevron=false,value=if(advanced)"−" else "+")
        if(advanced){GroupDivider()
          MobileToggle("启用提供商",enabled){enabled=it};GroupDivider()
          MobileToggle("验证 TLS 证书",verifyTLS){verifyTLS=it};GroupDivider()
          SettingField(contextWindow,{contextWindow=it},label=tr("上下文窗口"),singleLine=true)
          SettingField(proxy,{proxy=it},label=tr("代理 URL"),singleLine=true)
          SettingField(headers,{headers=it},label=tr("自定义请求头（JSON）"),minLines=3,maxLines=8,textStyle=MaterialTheme.typography.bodySmall.copy(fontFamily=FontFamily.Monospace))
          SettingField(parameters,{parameters=it},label=tr("模型参数（JSON）"),minLines=3,maxLines=8,textStyle=MaterialTheme.typography.bodySmall.copy(fontFamily=FontFamily.Monospace))
        }
        }
        if(model.settings.objects("providers").any{it.optString("id")==id})TextButton(onClick={deleteConfirmation=true}){Text(tr("删除提供商"),color=MaterialTheme.colorScheme.error)}
    }},confirmButton={TextButton(onClick={model.launch{val settings=JSONObject(model.settings.toString());val providers=model.settings.objects("providers").filter{it.optString("id")!=id}+provider();settings.put("providers",JSONArray(providers)).put("selected",id);model.aiCall(s,"settings.save",obj("settings" to settings));model.settings=settings;if(s.conversation.has("id"))s.conversation=model.aiCall(s,"conversation.draft",obj("conversationId" to s.conversation.optString("id"),"agent" to id));dismiss()}}){Text(tr("保存"))}})
    if(deleteConfirmation)AlertDialog(onDismissRequest={deleteConfirmation=false},title={Text(tr("删除提供商"))},text={Text(name)},confirmButton={TextButton(onClick={model.launch{
      val settings=JSONObject(model.settings.toString());val providers=settings.objects("providers").filter{it.optString("id")!=id};settings.put("providers",JSONArray(providers));if(settings.optString("selected")==id)settings.put("selected",providers.firstOrNull()?.optString("id")?:"")
      model.aiCall(s,"settings.save",obj("settings" to settings));model.settings=settings;deleteConfirmation=false;dismiss()
    }}){Text(tr("删除"))}},dismissButton={TextButton(onClick={deleteConfirmation=false}){Text(tr("取消"))}})
}

@Composable private fun ChatMessage(message:JSONObject){
    val user=message.optString("role")=="user"
    val tool=message.optString("role")=="tool"
    val text=message.optString("content")
    if(text.isBlank()&&message.objects("calls").isEmpty())return
    BoxWithConstraints(Modifier.fillMaxWidth()){
        val maxBubble=(maxWidth-32.dp).coerceAtLeast(0.dp)
        Row(Modifier.fillMaxWidth(),horizontalArrangement=if(user)Arrangement.End else Arrangement.Start){
            if(user)Surface(Modifier.widthIn(max=maxBubble).testTag("ai-user-bubble"),shape=RoundedCornerShape(MobileDesign.chatRadius),color=MaterialTheme.colorScheme.surface){SelectionContainer{Text(text,Modifier.padding(14.dp))}}
            else Column(Modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(10.dp)){
                if(tool)ToolDisclosure(tr("执行结果"),text)
                else if(text.isNotBlank())MarkdownView(text)
                message.objects("calls").forEach{call->
                    val args=call.optJSONObject("arguments")
                    ToolDisclosure(args?.optString("command")?.takeIf{it.isNotBlank()}?.let{"$ $it"}?:call.optString("name"),call.opt("arguments").toString())
                }
            }
        }
    }
}
@Composable private fun ToolDisclosure(title:String,body:String){
    var expanded by remember{mutableStateOf(false)}
    Surface(shape=RoundedCornerShape(MobileDesign.toolRadius),color=MaterialTheme.colorScheme.surface,border=androidx.compose.foundation.BorderStroke(.5.dp,MaterialTheme.colorScheme.outlineVariant)){
        Column{
            TextButton(onClick={expanded=!expanded},modifier=Modifier.fillMaxWidth(),contentPadding=PaddingValues(12.dp)){
                Icon(if(expanded)Icons.Outlined.ExpandLess else Icons.Outlined.ChevronRight,null,Modifier.size(18.dp));Spacer(Modifier.width(8.dp))
                Text(title,Modifier.weight(1f),maxLines=1,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if(expanded){HorizontalDivider();SelectionContainer{Text(body,Modifier.padding(14.dp),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall)}}
        }
    }
}
