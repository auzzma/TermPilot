package com.termpilot.app

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import org.json.JSONObject

@Composable fun MonitorPanel(model:AppModel,s:Session){
    var snapshot by remember(s.id){mutableStateOf(JSONObject())};var history by remember(s.id){mutableStateOf<List<Double>>(emptyList())}
    var error by remember{mutableStateOf<String?>(null)};var busy by remember{mutableStateOf(false)};var revision by remember{mutableIntStateOf(0)};var updated by remember{mutableStateOf("")}
    val parser=remember(s.id){MonitorParser()};val context=LocalContext.current;val lifecycle=LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(s.id,s.connected,s.execReady,s.filesReady,revision){lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED){while(true){
        if(!s.connected){error=tr("请先连接服务器");break};busy=true
        try{val info=model.files(s,obj("action" to "systemInfo"));snapshot=if(info.optString("platform")=="windows")model.files(s,obj("action" to "systemMonitor","operation" to "overview")) else {val script=context.assets.open("monitor.sh").bufferedReader().use{it.readText()};val result=model.exec(s,script);check(result.optInt("code")==0){result.optString("stderr")};parser.parse(result.optString("stdout"))};error=null;updated=java.text.DateFormat.getTimeInstance().format(java.util.Date());if(snapshot.optBoolean("cpuReady",true))snapshot.metric("cpuUsage")?.let{history=(history+it).takeLast(60)}}catch(e:CancellationException){throw e}catch(e:Exception){error=e.localizedMessage}finally{busy=false};delay(if(error==null)3000 else 10000)
    }}}
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),verticalArrangement=Arrangement.spacedBy(16.dp)){
        Row(verticalAlignment=Alignment.CenterVertically){Text(tr("实时监控"),Modifier.weight(1f),style=MaterialTheme.typography.titleMedium);if(busy)CircularProgressIndicator(Modifier.size(18.dp),strokeWidth=2.dp);IconButton(onClick={revision++}){Icon(Icons.Outlined.Refresh,tr("刷新"))}}
        error?.let{Text(it,color=MaterialTheme.colorScheme.error,style=MaterialTheme.typography.bodySmall)}
        MonitorDashboard(snapshot,s.host,history)
        if(updated.isNotEmpty())Text(tr("更新于")+" "+updated,style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable fun MonitorDashboard(data:JSONObject,host:JSONObject,history:List<Double>){
    val cpu=if(data.optBoolean("cpuReady",true))data.metric("cpuUsage")else null
    val total=data.metric("memoryTotal");val used=data.metric("memoryUsed");val memory=if(total!=null&&total>0&&used!=null)used*100/total else null
    val disk=data.objects("disks").firstOrNull()?:JSONObject()
    Column(Modifier.testTag("monitor-dashboard"),verticalArrangement=Arrangement.spacedBy(16.dp)){
        MonitorCard{Row(verticalAlignment=Alignment.CenterVertically){Icon(Icons.Outlined.Dns,null,Modifier.size(34.dp),tint=Color(0xff24b7d7));Spacer(Modifier.width(12.dp));Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(8.dp)){Text(host.optString("hostname"),style=MaterialTheme.typography.titleSmall,color=Color(0xff24b7d7));Text(host.optString("username")+" · "+data.optString("os","--"),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)};Column(horizontalAlignment=Alignment.End){Text(tr("运行时间"),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant);Text(data.optString("uptime","--"),style=MaterialTheme.typography.labelMedium,color=Color(0xff32b768))}}}
        Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
            MetricCard("CPU",Icons.Outlined.Memory,Color(0xff24b7d7),monitorPercent(cpu),cpu,tr("用户")+" "+monitorPercent(data.metric("cpuUserUsage"))+" · "+tr("系统")+" "+monitorPercent(data.metric("cpuSystemUsage")),Modifier.weight(1f))
            MetricCard(tr("内存"),Icons.Outlined.DeveloperBoard,Color(0xffba65dc),monitorPercent(memory),memory,monitorBytes(used)+" / "+monitorBytes(total),Modifier.weight(1f))
        }
        Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){
            MetricCard(tr("磁盘"),Icons.Outlined.Storage,Color(0xffe59a37),monitorPercent(disk.metric("percent")),disk.metric("percent"),monitorBytes(disk.metric("used"))+" / "+monitorBytes(disk.metric("total")),Modifier.weight(1f))
            MetricCard(tr("网络"),Icons.Outlined.Wifi,Color(0xff32b768),monitorBytes(data.metric("networkRxPerSecond"))+"/s",null,"↑ "+monitorBytes(data.metric("networkTxPerSecond"))+"/s",Modifier.weight(1f))
        }
        MonitorCard{Column(verticalArrangement=Arrangement.spacedBy(12.dp)){MonitorSection(tr("CPU 负载趋势"),Icons.Outlined.MonitorHeart,Color(0xff24b7d7));val grid=MaterialTheme.colorScheme.outlineVariant
            Canvas(Modifier.fillMaxWidth().height(130.dp)){for(i in 0..4)drawLine(grid,Offset(0f,size.height*i/4),Offset(size.width,size.height*i/4),1f);if(history.size>1){val path=Path();history.forEachIndexed{i,v->val x=size.width*i/(history.size-1);val y=size.height*(1-v.coerceIn(0.0,100.0).toFloat()/100);if(i==0)path.moveTo(x,y)else path.lineTo(x,y)};drawPath(path,Color(0xff24b7d7),style=Stroke(2.5.dp.toPx()))}}
            Row{Text("0–100%",style=MaterialTheme.typography.labelSmall);Spacer(Modifier.weight(1f));Text(tr(if(history.isEmpty())"等待采样" else "每 3 秒更新"),style=MaterialTheme.typography.labelSmall)}
        }}
        MonitorSection(tr("磁盘分区"),Icons.Outlined.Storage,Color(0xffe59a37))
        if(data.objects("disks").isEmpty())Text(tr("暂无数据"),style=MaterialTheme.typography.bodySmall)
        data.objects("disks").forEach{r->MonitorCard{Column(verticalArrangement=Arrangement.spacedBy(10.dp)){Row{Text(r.optString("mount"),Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium);Text(monitorBytes(r.metric("used"))+" / "+monitorBytes(r.metric("total")),style=MaterialTheme.typography.labelSmall)};LinearProgressIndicator(progress={(r.optDouble("percent",0.0)/100).toFloat().coerceIn(0f,1f)},modifier=Modifier.fillMaxWidth(),color=Color(0xffe59a37))}}}
        MonitorSection(tr("网络接口"),Icons.Outlined.Wifi,Color(0xff32b768))
        if(data.objects("networkInterfaces").isEmpty())Text(tr("暂无数据"),style=MaterialTheme.typography.bodySmall)
        data.objects("networkInterfaces").forEach{r->MonitorCard{Row(verticalAlignment=Alignment.CenterVertically){Text(r.optString("name"),Modifier.weight(1f),style=MaterialTheme.typography.bodyMedium);Column(horizontalAlignment=Alignment.End){Text("↓ "+monitorBytes(r.metric("rxPerSecond"))+"/s",style=MaterialTheme.typography.labelMedium,color=Color(0xff32b768));Text("↑ "+monitorBytes(r.metric("txPerSecond"))+"/s",style=MaterialTheme.typography.labelMedium,color=Color(0xff499bea))}}}}
        listOf(listOf("loadAverage" to "负载","os" to "系统"),listOf("kernel" to "内核","swap" to "交换分区")).forEach{row->Row(horizontalArrangement=Arrangement.spacedBy(12.dp)){row.forEach{(key,label)->MonitorCard(Modifier.weight(1f)){Column(verticalArrangement=Arrangement.spacedBy(8.dp)){Text(tr(label),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant);Text(data.optString(key,"--"),style=MaterialTheme.typography.bodySmall)}}}}}
        MonitorSection(tr("内存占用最高进程"),Icons.Outlined.Memory,Color(0xffdc6891))
        data.objects("topMemoryProcesses").forEach{r->MonitorCard{Column(verticalArrangement=Arrangement.spacedBy(10.dp)){Row{Text(r.optString("command"),Modifier.weight(1f),maxLines=2,style=MaterialTheme.typography.bodyMedium);Text("PID ${r.optLong("pid")}",style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant)};Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(10.dp)){Text("MEM",style=MaterialTheme.typography.labelSmall);LinearProgressIndicator(progress={(r.optDouble("memoryPercent",0.0)/100).toFloat().coerceIn(0f,1f)},modifier=Modifier.weight(1f),color=Color(0xffba65dc));Text(monitorPercent(r.metric("memoryPercent")),style=MaterialTheme.typography.labelSmall)}}}}
    }
}
@Composable fun MonitorCard(modifier:Modifier=Modifier,content:@Composable ()->Unit){OutlinedCard(modifier.fillMaxWidth(),shape=androidx.compose.foundation.shape.RoundedCornerShape(18.dp),colors=CardDefaults.outlinedCardColors(containerColor=MaterialTheme.colorScheme.surface)){Box(Modifier.padding(16.dp)){content()}}}
@Composable private fun MonitorSection(title:String,icon:ImageVector,color:Color){Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){Icon(icon,null,Modifier.size(20.dp),tint=color);Text(title,style=MaterialTheme.typography.titleSmall)}}
@Composable private fun MetricCard(title:String,icon:ImageVector,color:Color,value:String,percent:Double?,detail:String,modifier:Modifier){MonitorCard(modifier){Column(verticalArrangement=Arrangement.spacedBy(10.dp)){MonitorSection(title,icon,color);Text(value,style=MaterialTheme.typography.titleMedium,maxLines=1);if(percent!=null)LinearProgressIndicator(progress={(percent/100).toFloat().coerceIn(0f,1f)},modifier=Modifier.fillMaxWidth(),color=color);Text(detail,Modifier.heightIn(min=30.dp),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.onSurfaceVariant,maxLines=2)}}}
