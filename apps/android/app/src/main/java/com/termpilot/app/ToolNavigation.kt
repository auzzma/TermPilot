package com.termpilot.app

import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

data class MobileTool(val key:String,val title:String,val icon:ImageVector)
val mobileTools=listOf(MobileTool("files","文件",Icons.Outlined.Folder),MobileTool("monitor","监控",Icons.Outlined.MonitorHeart),MobileTool("scripts","脚本",Icons.Outlined.Terminal),MobileTool("tmux","tmux",Icons.Outlined.GridView),MobileTool("commands","历史",Icons.Outlined.History),MobileTool("notes","笔记",Icons.Outlined.Notes),MobileTool("forwards","转发",Icons.Outlined.SwapHoriz))
@Composable fun ToolDock(selected:String,ssh:Boolean,select:(String)->Unit){
    val group=if(selected in listOf("monitor","processes","docker","images"))"monitor" else if(selected=="history")"commands" else selected
    Surface(color=MaterialTheme.colorScheme.surface){Column(Modifier.testTag("tool-bottom-navigation")){
        HorizontalDivider()
        val sections=when(group){"monitor"->listOf("monitor" to "概览","processes" to "进程","docker" to "Docker","images" to "镜像");"commands"->listOf("commands" to "命令历史","history" to "连接历史");else->emptyList()}
        if(sections.isNotEmpty())MobileSegments(sections,selected,select,"tool-section-",Modifier.padding(horizontal=12.dp,vertical=8.dp))
        BoxWithConstraints(Modifier.fillMaxWidth()){
        val itemWidth=((maxWidth-32.dp)/7).coerceIn(48.dp,80.dp)
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal=10.dp,vertical=6.dp),horizontalArrangement=Arrangement.spacedBy(2.dp)){
            mobileTools.forEach { tool ->
                val active = group == tool.key
                val enabled = ssh || tool.key == "files"
                val foreground = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                Column(
                    Modifier.width(itemWidth).clip(RoundedCornerShape(12.dp)).background(if(active)MaterialTheme.colorScheme.primary.copy(alpha=.13f)else Color.Transparent).heightIn(min=56.dp).testTag("tool-${tool.key}")
                        .selectable(active, enabled = enabled, role = Role.Tab, onClick = { select(tool.key) })
                        .padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)
                ) {
                    Icon(tool.icon, null, Modifier.size(21.dp), tint = foreground.copy(alpha = if(enabled) 1f else .38f))
                    Text(tr(tool.title), maxLines = 1, style = MaterialTheme.typography.labelSmall, color = foreground.copy(alpha = if(enabled) 1f else .38f))
                }
            }
        }
        }
    }}
}
