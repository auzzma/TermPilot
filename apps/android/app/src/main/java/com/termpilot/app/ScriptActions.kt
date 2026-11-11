package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import org.json.JSONObject

@Composable fun ScriptActions(model:AppModel,record:JSONObject,current:Session) {
 var target by remember{mutableStateOf(current.id)}
 var confirmation by remember{mutableStateOf(false)}
 val choices=model.sessions.filter{it.protocol=="ssh"&&it.connected}
 val session=choices.find{it.id==target}
 Choice(tr("目标服务器"),target.toString(),choices.map{it.id.toString() to it.label}){target=it.toLong()}
 Row {
  TextButton(enabled=session!=null,onClick={val s=session?:return@TextButton;model.launch{
   val body=record.optString("body").trimEnd('\r','\n')
   val snapshot=model.call(obj("method" to "terminal.snapshot","id" to s.terminal))
   val bracketed=snapshot.optBoolean("bracketedPaste")
   check(bracketed||('\n' !in body&&'\r' !in body)){tr("当前终端未启用安全粘贴，多行脚本请使用执行操作")}
   check('\u001b' !in body){tr("快捷命令不能包含终端控制序列")}
   model.selected=s.id;s.activePanel="terminal"
   model.text(s,if(bracketed)"\u001b[200~$body\u001b[201~" else body)
  }}){Text(tr("插入终端"))}
  TextButton(enabled=session!=null,onClick={confirmation=true}){Text(tr("执行…"))}
 }
 if(confirmation)AlertDialog(onDismissRequest={confirmation=false},title={Text(tr("确认执行脚本"))},text={Column(Modifier.verticalScroll(rememberScrollState())){
  Text(trf("目标：{}",session?.label?:tr("已断开")));Text(trf("账号：{}",session?.host?.optString("username")?:""));Text(record.optString("shell","/bin/sh"));Text(record.optString("body"),fontFamily=FontFamily.Monospace)
 }},confirmButton={TextButton(enabled=session!=null,onClick={val s=session?:return@TextButton;model.launch{
  val info=model.files(s,obj("action" to "systemInfo"))
  val plan=model.call(obj("method" to "mobile.serverTool","operation" to "script","value" to record.optString("body"),"shell" to record.optString("shell","/bin/sh"),"platform" to info.optString("platform")))
  model.selected=s.id;s.activePanel="terminal";model.text(s,plan.optString("command")+"\n");confirmation=false
 }}){Text(tr("执行"))}},dismissButton={TextButton(onClick={confirmation=false}){Text(tr("取消"))}})
}
