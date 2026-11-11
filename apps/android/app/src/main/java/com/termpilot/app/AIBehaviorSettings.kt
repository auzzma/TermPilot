package com.termpilot.app
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import org.json.JSONObject
import org.json.JSONArray

@Composable fun AIBehaviorDialog(model:AppModel,s:Session,section:String="safety",dismiss:()->Unit) {
 val search=model.settings.optJSONObject("search")?:JSONObject()
 var timeout by remember{mutableStateOf(model.settings.optInt("commandTimeout",60).toString())}
 var iterations by remember{mutableStateOf(model.settings.optInt("maxIterations",20).toString())}
 var blacklist by remember{mutableStateOf((model.settings.optJSONArray("commandBlacklist")?:JSONArray()).let{a->(0 until a.length()).joinToString("\n"){a.getString(it)}})}
 var enabled by remember{mutableStateOf(search.optBoolean("enabled"))}
 var kind by remember{mutableStateOf(search.optString("kind","tavily"))}
 var endpoint by remember{mutableStateOf(search.optString("endpoint"))}
 var apiKey by remember{mutableStateOf(search.optString("apiKey"))}
 var maxResults by remember{mutableStateOf(search.optInt("maxResults",5).toString())}
 FormPage(onDismissRequest=dismiss,editing=true,title={Text(tr(if(section=="search")"网络搜索" else "行为与安全"))},text={Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
  if(section!="search")GroupedSection("命令执行"){Text(tr("命令执行沿用共享内核的审批模式；命令黑名单始终生效。"),Modifier.padding(16.dp),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
  GroupDivider();MobileStepper("命令超时（秒）",timeout.toIntOrNull()?:60,1..86400){timeout=it.toString()};GroupDivider()
  MobileStepper("最大工具轮次",iterations.toIntOrNull()?:20,1..100){iterations=it.toString()};GroupDivider()
  SettingField(blacklist,{blacklist=it},label=tr("命令黑名单 · 每行一条正则表达式"),minLines=4,maxLines=8,textStyle=MaterialTheme.typography.bodySmall.copy(fontFamily=androidx.compose.ui.text.font.FontFamily.Monospace))
  }
  if(section=="search")GroupedSection("网络搜索"){MobileToggle("启用网络搜索",enabled){enabled=it};GroupDivider()
  Choice(tr("提供商"),kind,listOf("tavily","exa","bocha","zhipu","searxng").map{it to it}){kind=it};GroupDivider()
  SettingField(endpoint,{endpoint=it},label=tr("服务地址（留空使用默认）"),singleLine=true);GroupDivider()
  SettingField(apiKey,{apiKey=it},label="API Key",singleLine=true,visualTransformation=PasswordVisualTransformation())
  GroupDivider();MobileStepper("搜索结果数量",maxResults.toIntOrNull()?:5,1..20){maxResults=it.toString()}
 }
 }},confirmButton={TextButton(onClick={model.launch{
  val n=iterations.toInt();check(n in 1..100);check(timeout.toInt() in 1..86400);check(maxResults.toInt() in 1..20)
  val settings=JSONObject(model.settings.toString()).put("commandTimeout",timeout.toInt()).put("maxIterations",n).put("commandBlacklist",JSONArray(blacklist.lines().filter{it.isNotBlank()}))
  settings.put("search",JSONObject(search.toString()).put("enabled",enabled).put("kind",kind).put("endpoint",endpoint).put("apiKey",apiKey).put("maxResults",maxResults.toInt()))
  model.aiCall(s,"settings.save",obj("settings" to settings));model.settings=settings;dismiss()
 }}){Text(tr("保存"))}})
}
