package com.termpilot.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Save
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.graphics.luminance
import androidx.core.view.WindowCompat
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun FileEditor(model:AppModel,s:Session,operation:String,path:String,dismiss:()->Unit){
    var value by remember{mutableStateOf("")};var original by remember{mutableStateOf("")}
    var loaded by remember{mutableStateOf(false)};var busy by remember{mutableStateOf(false)}
    var error by remember{mutableStateOf<String?>(null)};var discard by remember{mutableStateOf(false)}
    val title=mapOf("mkdir" to tr("新建文件夹"),"rename" to tr("重命名"),"chmod" to tr("权限"),"writeText" to tr("编辑文本"),"delete" to tr("删除文件"))[operation]?:tr("文件")
    fun close(){if(busy)return;if(operation=="writeText"&&loaded&&value!=original)discard=true else dismiss()}
    fun save(){model.launch{busy=true;error=null;try{
        val r=obj("action" to operation,"path" to path)
        when(operation){
            "mkdir","rename"->{check(value.isNotBlank()&&!value.contains('/')&&value!="."&&value!=".."){tr("文件名称无效")};if(operation=="mkdir")r.put("path",path.trimEnd('/')+"/"+value)else r.put("oldPath",path).put("newPath",path.substringBeforeLast('/')+"/"+value)}
            "chmod"->{val mode=value.toIntOrNull(8);check(mode!=null&&mode in 0..4095){tr("请输入有效的八进制权限")};r.put("permissions",mode)}
            "writeText"->{check(model.files(s,obj("action" to "readText","path" to path)).optString("text")==original){tr("远端文件已变化，请重新打开后编辑")};r.put("content",value).put("overwrite",true)}
        }
        model.files(s,r);original=value;model.list(s);dismiss()
    }catch(e:kotlinx.coroutines.CancellationException){throw e}catch(e:Exception){error=e.localizedMessage}finally{busy=false}}}
    LaunchedEffect(path,operation){try{value=when(operation){"writeText"->model.files(s,obj("action" to "readText","path" to path)).optString("text");"rename"->path.substringAfterLast('/');"chmod"->(model.files(s,obj("action" to "stat","path" to path)).getJSONObject("entry").optInt("permissions") and 4095).toString(8);else->""};original=value;loaded=true}catch(e:kotlinx.coroutines.CancellationException){throw e}catch(e:Exception){error=e.localizedMessage}}
    if(operation=="writeText")Dialog(onDismissRequest={close()},properties=DialogProperties(usePlatformDefaultWidth=false,decorFitsSystemWindows=false)){
        val dialogView=LocalView.current
        val lightBars=MaterialTheme.colorScheme.surface.luminance()>.5f
        SideEffect { (dialogView.parent as? DialogWindowProvider)?.window?.let { window ->
            WindowCompat.getInsetsController(window,dialogView).apply { isAppearanceLightStatusBars=lightBars;isAppearanceLightNavigationBars=lightBars }
        } }
        Surface(Modifier.fillMaxSize().testTag("file-editor-page")){
            BackHandler{close()}
            Scaffold(modifier=Modifier.safeDrawingPadding().imePadding(),topBar={MobileNavigationHeader(title={Text(path.substringAfterLast('/'),maxLines=1,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis)},onBack={close()},actions={TextButton(enabled=loaded&&!busy&&value!=original,onClick={save()}){Text(tr("保存"))}})},bottomBar={Text(trf("{} 行 · {} 字符",(value.count{it=='\n'}+1).toString(),value.length.toString())+if(value!=original)" · "+tr("未保存") else "",Modifier.padding(horizontal=16.dp,vertical=8.dp),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}){padding->
                Column(Modifier.padding(padding).fillMaxSize()){
                    Text(path,Modifier.padding(horizontal=16.dp,vertical=8.dp),maxLines=2,overflow=androidx.compose.ui.text.style.TextOverflow.Ellipsis,style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                    HorizontalDivider()
                    if(!loaded&&error==null||busy)LinearProgressIndicator(Modifier.fillMaxWidth())
                    error?.let{Text(it,Modifier.padding(16.dp),color=MaterialTheme.colorScheme.error)}
                    BasicTextField(value,{value=it},readOnly=!loaded||busy,textStyle=MaterialTheme.typography.bodyMedium.copy(fontFamily=FontFamily.Monospace,color=MaterialTheme.colorScheme.onSurface),cursorBrush=androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),modifier=Modifier.weight(1f).fillMaxWidth().padding(16.dp).verticalScroll(rememberScrollState()).testTag("file-editor-text"))
                }
            }
        }
    }else AlertDialog(onDismissRequest={close()},title={Text(title)},text={Column(verticalArrangement=Arrangement.spacedBy(12.dp)){Text(path,style=MaterialTheme.typography.bodySmall);if(operation=="delete")Text(tr("将删除此文件或文件夹及其内容。"))else OutlinedTextField(value,{value=it},label={Text(if(operation=="chmod")tr("八进制权限，例如 644") else title)},singleLine=true);error?.let{Text(it,color=MaterialTheme.colorScheme.error)};if(busy)LinearProgressIndicator(Modifier.fillMaxWidth())}},confirmButton={TextButton(enabled=loaded&&!busy,onClick={save()}){Text(if(operation=="delete")tr("删除") else tr("保存"))}},dismissButton={TextButton(onClick={close()}){Text(tr("取消"))}})
    if(discard)AlertDialog(onDismissRequest={discard=false},title={Text(tr("放弃未保存的修改？"))},confirmButton={TextButton(onClick={discard=false;dismiss()}){Text(tr("放弃修改"))}},dismissButton={TextButton(onClick={discard=false}){Text(tr("继续编辑"))}})
}
