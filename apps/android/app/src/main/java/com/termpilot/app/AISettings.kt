package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable fun AISettingsDialog(model:AppModel,s:Session,dismiss:()->Unit){
    var page by remember { mutableStateOf("") }
    var provider by remember { mutableStateOf<String?>(null) }
    var behavior by remember { mutableStateOf<String?>(null) }
    FormPage(onDismissRequest={if(page.isEmpty())dismiss()else page=""},title={Text(tr(when(page){"providers"->"提供商";"agents"->"Agent";"tools"->"工具接入";else->"AI 设置"}))},text={
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
            when(page){
                ""->{
                    GroupedSection("模型与助手"){
                        SettingRow("提供商",Icons.Outlined.Cloud,value="${model.settings.objects("providers").size}",onClick={page="providers"});GroupDivider(57.dp)
                        SettingRow("Agent",Icons.Outlined.AutoAwesome,value="TermPilot Agent",onClick={page="agents"})
                    }
                    GroupedSection("能力与权限"){
                        SettingRow("工具接入",Icons.Outlined.Extension,onClick={page="tools"});GroupDivider(57.dp)
                        SettingRow("网络搜索",Icons.Outlined.TravelExplore,onClick={behavior="search"});GroupDivider(57.dp)
                        SettingRow("行为与安全",Icons.Outlined.Shield,onClick={behavior="safety"})
                    }
                    Text(tr("AI 对话绑定当前服务器。配置可在所有会话中使用。"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
                }
                "providers"->{
                    GroupedSection("已保存的提供商"){
                        if(model.settings.objects("providers").isEmpty())SettingRow("暂无提供商",subtitle=tr("添加 API 配置后即可开始对话"))
                        model.settings.objects("providers").forEachIndexed{index,p->if(index>0)GroupDivider(57.dp);SettingRow(p.optString("name"),Icons.Outlined.Cloud,value=if(p.optString("id")==model.settings.optString("selected"))tr("默认")else "",subtitle=p.optString("model"),onClick={provider=p.optString("id")})}
                    }
                    GroupedSection{SettingRow("新增提供商",Icons.Outlined.Add,onClick={provider="new"})}
                }
                "agents"->{
                    GroupedSection("内置助手"){SettingRow("TermPilot Agent",Icons.Outlined.AutoAwesome,subtitle=tr("使用提供商模型分析服务器、执行命令和调用工具。"))}
                    GroupedSection("外部 Agent",footer="移动端不运行本地外部 Agent。请在桌面端配置与使用。"){SettingRow("Codex / Claude Code",value=tr("仅桌面端"))}
                }
                "tools"->{
                    GroupedSection("会话工具",footer="工具只作用于当前连接的服务器，并遵循命令审批设置。"){SettingRow("终端上下文",Icons.Outlined.Terminal);GroupDivider(57.dp);SettingRow("命令执行与任务管理",Icons.Outlined.Build)}
                    GroupedSection("MCP",footer="移动端暂不支持启用 MCP 服务。"){SettingRow("MCP 服务",value=tr("仅桌面端"))}
                }
            }
        }
    })
    provider?.let{id->ProviderDialog(model,s,id){provider=null}}
    behavior?.let{section->AIBehaviorDialog(model,s,section){behavior=null}}
}
