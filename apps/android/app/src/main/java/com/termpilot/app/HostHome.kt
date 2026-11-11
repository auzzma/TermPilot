package com.termpilot.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable fun HostHome(model:AppModel,onEdit:(JSONObject)->Unit,onGroups:()->Unit){
    var menuHost by remember{mutableStateOf<JSONObject?>(null)}
    var duplicate by remember{mutableStateOf<JSONObject?>(null)}
    var deleting by remember{mutableStateOf<JSONObject?>(null)}
    duplicate?.let{draft->RecordDialog(model,"hosts",draft.getJSONObject("item"),initialProfile=draft.optJSONObject("screenSharingProfile"),isNew=true){duplicate=null}}
    deleting?.let{host->AlertDialog(onDismissRequest={deleting=null},title={Text(tr("删除"))},text={Text(host.optString("label"))},confirmButton={TextButton(onClick={deleting=null;model.launch{model.delete("hosts",host.optString("id"))}}){Text(tr("删除"))}},dismissButton={TextButton(onClick={deleting=null}){Text(tr("取消"))}})}
    var search by remember{mutableStateOf("")}
    val context=androidx.compose.ui.platform.LocalContext.current
    val preferences=remember{context.getSharedPreferences("TermPilot.ui",android.content.Context.MODE_PRIVATE)}
    var collapsed by remember{mutableStateOf(preferences.getStringSet("collapsedHostGroups",emptySet())!!.toSet())}
    fun collapse(ids:Set<String>){collapsed=ids;preferences.edit().putStringSet("collapsedHostGroups",ids).apply()}
    val hosts=model.records["hosts"].orEmpty()
    val groupRecords=model.records["groups"].orEmpty()
    val roots=hostGroupTree(groupRecords.mapIndexed{i,g->HostGroupInfo(g.optString("id"),g.optString("name"),g.optString("parentGroupID").takeUnless{it=="null"}?:"",g.optInt("sortOrder",i))})
    val known=groupRecords.map{it.optString("id")}.toSet()
    val grouped=hosts.groupBy{it.optString("groupID").takeIf{it in known}?:""}
    val ungrouped=HostGroupNode(HostGroupInfo("",tr("未分组")),emptyList())
    val tree=roots+if(grouped[""].isNullOrEmpty())emptyList()else listOf(ungrouped)
    val rows=hostTreeRows(tree,grouped.mapValues{(_,list)->list.map{it.optString("id") to (it.optString("label")+" "+it.optString("hostname"))}},collapsed,search)
    val byID=hosts.associateBy{it.optString("id")}
    Column(Modifier.fillMaxSize()){
        LargePageTitle("主机"){IconButton(onClick={onEdit(JSONObject())}){Icon(Icons.Outlined.Add,tr("新增主机"))}}
        MobileSearchField(search,{search=it},tr("搜索主机"),Modifier.padding(horizontal=MobileDesign.pageInset))
        LazyColumn(contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
            item{GroupedSection{
                SettingRow("快速连接",Icons.Outlined.Bolt,onClick={onEdit(obj("_quick" to true))});GroupDivider(57.dp)
                SettingRow("分组设置",Icons.Outlined.CreateNewFolder,onClick=onGroups)
            }}
            if(tree.isNotEmpty())item{Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.End){
                TextButton(onClick={collapse(emptySet())}){Text(tr("全部展开"))}
                TextButton(onClick={collapse(tree.flatMap{it.descendants()}.toSet())}){Text(tr("全部收起"))}
            }}
            item{GroupedSection{rows.forEachIndexed{index,row->
                if(index>0)GroupDivider((16+row.depth.coerceAtMost(5)*16).dp)
                key(row.id){
                    val group=row.group
                    if(group!=null){
                        Row(Modifier.fillMaxWidth().testTag(row.id).clickable{collapse(if(group.group.id in collapsed)collapsed-group.group.id else collapsed+group.group.id)}
                            .padding(start=(14+row.depth.coerceAtMost(5)*16).dp,end=14.dp).heightIn(min=50.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){
                            Icon(if(row.expanded)Icons.Outlined.ExpandMore else Icons.Outlined.ChevronRight,tr(if(row.expanded)"收起" else "展开"),Modifier.size(18.dp))
                            Icon(if(row.expanded)Icons.Outlined.FolderOpen else Icons.Outlined.Folder,null,Modifier.size(21.dp),tint=MaterialTheme.colorScheme.primary)
                            Text(group.group.name,Modifier.weight(1f),style=MaterialTheme.typography.titleSmall)
                            Text(row.count.toString(),style=MaterialTheme.typography.labelMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }else byID[row.hostID]?.let{host->
                        Row(Modifier.fillMaxWidth().testTag(row.id).padding(start=(row.depth.coerceAtMost(5)*16).dp),verticalAlignment=Alignment.CenterVertically){
                            Row(Modifier.weight(1f).combinedClickable(onClick={model.launch{model.connect(host)}},onLongClick={menuHost=host}).padding(14.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
                                Surface(shape=RoundedCornerShape(10.dp),color=MaterialTheme.colorScheme.primaryContainer){Icon(if(host.optString("connectionKind","ssh")=="ssh")Icons.Outlined.Terminal else Icons.Outlined.DesktopWindows,null,Modifier.padding(9.dp).size(18.dp),tint=MaterialTheme.colorScheme.primary)}
                                Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(4.dp)){Text(host.optString("label"),style=MaterialTheme.typography.bodyLarge);Text(host.optString("hostname"),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}
                            }
                            IconButton(onClick={onEdit(host)}){Icon(Icons.Outlined.Info,tr("编辑")+" "+host.optString("label"),Modifier.size(19.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)}
                            DropdownMenu(expanded=menuHost?.optString("id")==host.optString("id"),onDismissRequest={menuHost=null}){
                                DropdownMenuItem(text={Text(tr("编辑"))},onClick={menuHost=null;onEdit(host)})
                                DropdownMenuItem(text={Text(tr("复制主机"))},leadingIcon={Icon(Icons.Outlined.ContentCopy,null)},onClick={menuHost=null;model.launch{
                                    val draft=model.call(obj("method" to "vault.host.duplicateDraft","id" to host.optString("id")))
                                    draft.getJSONObject("item").let{it.put("label",it.optString("label")+" "+tr("副本"))};duplicate=draft
                                }})
                                DropdownMenuItem(text={Text(tr("删除"))},onClick={menuHost=null;deleting=host})
                            }
                        }
                    }
                }
            }}}
            if(model.ready&&rows.isEmpty())item{Column(Modifier.fillMaxWidth().padding(28.dp),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(14.dp)){Icon(Icons.Outlined.Dns,null,Modifier.size(36.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant);Text(tr(if(search.isBlank())"添加第一台服务器" else "暂无数据"));Text("SSH · VNC · RDP · Apple",style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)}}
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SessionsHome(model:AppModel,quick:()->Unit){
    Column(Modifier.fillMaxSize()){
        LargePageTitle("会话"){IconButton(onClick=quick){Icon(Icons.Outlined.Add,tr("快速连接"))}}
        LazyColumn(contentPadding=PaddingValues(16.dp)){
            if(model.sessions.isEmpty())item{Text(tr("暂无会话"),Modifier.padding(16.dp),color=MaterialTheme.colorScheme.onSurfaceVariant)}
            else item{GroupedSection("活动会话"){model.sessions.forEachIndexed{index,s->if(index>0)GroupDivider();Row(verticalAlignment=Alignment.CenterVertically){Box(Modifier.weight(1f)){SettingRow(s.label,if(s.protocol=="ssh")Icons.Outlined.Terminal else Icons.Outlined.DesktopWindows,subtitle=tr(s.status),onClick={model.selected=s.id})};IconButton(onClick={model.launch{model.close(s)}}){Icon(Icons.Outlined.Close,tr("断开"))}}}}}
        }
    }
}

@Composable fun HomeNavigation(selected:String,choose:(String)->Unit){
    MobileTabBar(listOf(MobileTab("hosts","主机",Icons.Outlined.Dns),MobileTab("sessions","会话",Icons.Outlined.ContentCopy),MobileTab("settings","设置",Icons.Outlined.Settings)),selected,choose,"home-")
}
