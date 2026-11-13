package com.termpilot.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.semantics.Role

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SettingsPanel(model:AppModel,open:(String)->Unit){
    val appVersion=installedAppVersion()
    var page by remember { mutableStateOf("") }
    var showsLicense by remember { mutableStateOf(false) }
    fun back(){page=if(page=="videoCodec") "terminal" else if(page in listOf("appearance","language","terminal","fps","videoCodec"))"general" else ""}
    BackHandler(page.isNotEmpty()){back()}
    BoxWithConstraints(Modifier.fillMaxSize()){
    val wide=maxWidth>=MobileDesign.wideBreakpoint
    val shown=if(wide&&page.isEmpty())"general" else page
    val title=mapOf("" to "设置","general" to "通用","appearance" to "外观","language" to "语言","terminal" to "终端","fps" to "远程桌面帧率上限","videoCodec" to "Apple 高性能视频编码","tools" to "工具与快捷键","about" to "关于 TermPilot")[shown]?:"设置"
    Row(Modifier.fillMaxSize()){
      if(wide){Column(Modifier.width(MobileDesign.sidebarWidth).fillMaxHeight().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){Text(tr("设置"),style=MaterialTheme.typography.headlineLarge);SettingsHomeGroups(model,open){page=it}};VerticalDivider()}
      Column(Modifier.weight(1f).fillMaxHeight()){
        if(shown.isEmpty())LargePageTitle(title)
        else MobileNavigationHeader(title={Text(tr(title))},onBack=if(!wide || page in listOf("appearance","language","terminal","fps","videoCodec"))({back()})else null)

        Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.TopCenter){
            Column(Modifier.widthIn(max=MobileDesign.formWidth).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
                when(shown){
                    ""->SettingsHomeGroups(model,open){page=it}
                    "general"->{
                        GroupedSection("显示"){
                            SettingRow("外观",value=tr(when(model.theme){"light"->"浅色";"system"->"跟随系统";else->"深色"}),onClick={page="appearance"});GroupDivider()
                            SettingRow("语言",value=when(model.language){"en"->"English";"system"->tr("跟随系统");else->"简体中文"},onClick={page="language"})
                        }
                        GroupedSection("会话"){
                            SettingRow("终端",value="${model.fontSize.toInt()} pt",onClick={page="terminal"});GroupDivider()
                            SettingRow("远程桌面帧率上限",value="${model.fps} FPS",onClick={page="fps"})
                        }
                        Text(tr("后台连接受系统限制。返回后请确认会话状态；不会自动重放命令。"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    "appearance"->{
                        GroupedSection("预览"){Text("root@home ~ $ uptime\nup 12 days, load average: 0.12",Modifier.padding(16.dp),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodyMedium)}
                        GroupedSection{listOf("dark" to "深色","light" to "浅色","system" to "跟随系统").forEach{(key,label)->OptionRow(tr(label),model.theme==key){model.appearance(theme=key)}}}
                    }
                    "language"->GroupedSection{listOf("zh-Hans" to "简体中文","en" to "English","system" to tr("跟随系统")).forEach{(key,label)->OptionRow(label,model.language==key){model.chooseLanguage(key)}}}
                    "terminal"->{
                        GroupedSection("预览"){Text("root@home ~ $ ls\nDocuments  Downloads",Modifier.padding(16.dp),fontFamily=FontFamily.Monospace,fontSize=model.fontSize.sp)}
                        GroupedSection("文字"){SettingRow("字号",value="${model.fontSize.toInt()} pt");Slider(model.fontSize,{model.setTerminalFont(it)},valueRange=10f..28f,steps=17,modifier=Modifier.padding(horizontal=16.dp).testTag("terminal-font-slider"))}
                        GroupedSection(footer="用于 Apple 高性能屏幕共享，下次连接时生效。"){SettingRow("Apple 高性能视频编码",value=if(model.videoCodec=="h265") "H.265" else "H.264",onClick={page="videoCodec"})}
                        GroupedSection("输入"){SettingRow("快捷键栏",onClick={open("keybar")})}
                    }
                    "videoCodec"->GroupedSection(footer="用于 Apple 高性能屏幕共享，下次连接时生效。"){listOf("h264" to "H.264","h265" to "H.265").forEach{(value,label)->OptionRow(label,model.videoCodec==value){model.chooseVideoCodec(value)}}}
                    "fps"->GroupedSection(footer="实际帧率取决于连接方式、远端与网络性能。"){listOf(30,60).forEach{value->OptionRow("$value FPS",model.fps==value){model.appearance(fps=value)}}}
                    "tools"->{
                        GroupedSection("输入"){SettingRow("快捷键栏",onClick={open("keybar")})}
                        GroupedSection("保存的配置"){listOf("groups" to "主机分组","scripts" to "脚本","notes" to "笔记","forwards" to "端口转发").forEachIndexed{index,(key,label)->if(index>0)GroupDivider();SettingRow(label,onClick={open(key)})}}
                    }
                    "about"->{
                        GroupedSection{SettingRow("应用名称",value="TermPilot");GroupDivider();SettingRow("版本",value=appVersion)}
                        GroupedSection("开源许可"){SettingRow("GNU General Public License v3.0",onClick={showsLicense=true})}
                    }
                }
            }
        }
    }
    }
    }
    if(showsLicense)GPLLicenseDialog{showsLicense=false}
}

@Composable private fun installedAppVersion():String {
    val context=androidx.compose.ui.platform.LocalContext.current
    return remember(context){context.packageManager.getPackageInfo(context.packageName,0).versionName.orEmpty()}
}

@Composable private fun GPLLicenseDialog(close:()->Unit){
    val context=androidx.compose.ui.platform.LocalContext.current
    val maxHeight=androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp * 0.6f
    val text=remember(context){runCatching{context.assets.open("GPL-3.0.txt").bufferedReader(Charsets.UTF_8).use{it.readText()}}.getOrNull()}
    AlertDialog(
        onDismissRequest=close,
        title={Text("GNU General Public License v3.0")},
        text={androidx.compose.foundation.text.selection.SelectionContainer{
            Text(text?:tr("无法加载许可文本。"),Modifier.heightIn(max=maxHeight).verticalScroll(rememberScrollState()).testTag("gpl-license-text"),
                style=MaterialTheme.typography.bodySmall,fontFamily=FontFamily.Monospace)
        }},
        confirmButton={TextButton(onClick=close,modifier=Modifier.testTag("close-gpl-license")){Text(tr("完成"))}}
    )
}

@Composable private fun ColumnScope.SettingsHomeGroups(model:AppModel,open:(String)->Unit,select:(String)->Unit){
                        val appVersion=installedAppVersion()

                        GroupedSection("偏好设置"){
                            SettingRow("通用",Icons.Outlined.Tune,onClick={select("general")});GroupDivider(57.dp)
                            SettingRow("AI",Icons.Outlined.AutoAwesome,onClick={open("ai")})
                        }
                        GroupedSection("连接与工具"){
                            SettingRow("凭证与密钥",Icons.Outlined.Key,onClick={open("credentials")});GroupDivider(57.dp)
                            SettingRow("代理配置",Icons.Outlined.Language,onClick={open("proxies")});GroupDivider(57.dp)
                            SettingRow("工具与快捷键",Icons.Outlined.Build,onClick={select("tools")})
                        }
                        GroupedSection("数据与支持"){
                            SettingRow("数据同步",Icons.Outlined.CloudSync,onClick={open("sync")});GroupDivider(57.dp)
                            SettingRow("传输记录",Icons.Outlined.SwapVert,onClick={open("transfers")});GroupDivider(57.dp)
                            SettingRow("备份与恢复",Icons.Outlined.Inventory2,onClick={open("backup")});GroupDivider(57.dp)
                            SettingRow("关于 TermPilot",Icons.Outlined.Info,onClick={select("about")})
                        }
                        Text("TermPilot · $appVersion",Modifier.align(Alignment.CenterHorizontally),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                    
}

@Composable fun OptionRow(label:String,selected:Boolean,choose:()->Unit){
    Row(Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).selectable(selected,role=Role.RadioButton,onClick=choose).padding(horizontal=MobileDesign.rowInset,vertical=12.dp),verticalAlignment=Alignment.CenterVertically){
        Text(label,Modifier.weight(1f),style=MaterialTheme.typography.bodyLarge)
        if(selected)Icon(Icons.Outlined.Check,null,Modifier.size(20.dp),tint=MaterialTheme.colorScheme.primary)
    }
}
