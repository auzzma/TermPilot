package com.termpilot.app

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

fun JSONObject.metric(key:String):Double?=if(has(key)&&!isNull(key))optDouble(key).takeIf{it.isFinite()}else null
fun monitorBytes(value:Double?):String { if(value==null||!value.isFinite()||value<0)return "--";val units=listOf("B","KiB","MiB","GiB","TiB");var v=value;var i=0;while(v>=1024&&i<4){v/=1024;i++};return String.format(Locale.getDefault(),if(i==0)"%.0f %s" else "%.1f %s",v,units[i]) }
fun monitorPercent(value:Double?):String=value?.let{String.format(Locale.getDefault(),"%.1f%%",it)}?:"--"
class MonitorParser {
    private var time:Double?=null
    private var cpu=emptyList<Double>()
    private var interfaces=emptyMap<String,List<Double>>()
    fun parse(output:String):JSONObject{
        val lines=output.lineSequence().map{it.split('=',limit=2)}.filter{it.size==2}.toList()
        val values=lines.associate{it[0] to it[1]}
        fun n(key:String)=values[key]?.toDoubleOrNull()?.takeIf{it.isFinite()}
        val total=n("MEM_TOTAL_MB");check(total!=null&&total>0){tr("无法获取监控数据")}
        val now=n("SAMPLE_TIME");val elapsed=if(now!=null&&time!=null)now-time!! else null
        val timed=elapsed!=null&&elapsed>0&&elapsed<60
        val raw=values["CPU_RAW"]?.split('|')?.mapNotNull{it.toDoubleOrNull()}?:emptyList()
        var usage=n("CPU");var user=n("CPU_USER");var system=n("CPU_SYS")
        if(raw.size==4&&cpu.size==4&&raw[0]>cpu[0]&&raw.zip(cpu).all{it.first>=it.second}){
            val d=raw[0]-cpu[0];usage=(100*(1-(raw[1]-cpu[1])/d)).coerceIn(0.0,100.0);user=(100*(raw[2]-cpu[2])/d).coerceIn(0.0,100.0);system=(100*(raw[3]-cpu[3])/d).coerceIn(0.0,100.0)
        }
        val disks=JSONArray();val tops=JSONArray();val network=JSONArray();val counters=mutableMapOf<String,List<Double>>()
        lines.forEach{(key,value)->val v=value.split('|');when{
            key=="DISK"&&v.size>=4->disks.put(obj("mount" to v[0],"used" to ((v[1].toDoubleOrNull()?:0.0)*1073741824),"total" to ((v[2].toDoubleOrNull()?:0.0)*1073741824),"percent" to (v[3].toDoubleOrNull()?:0.0)))
            key=="TOPPROC"&&v.size>=3->tops.put(obj("pid" to (v[0].toIntOrNull()?:0),"memoryPercent" to (v[1].toDoubleOrNull()?:0.0),"command" to v[2]))
            key=="NETIF_BYTES"&&v.size>=3->{val rx=v[1].toDoubleOrNull();val tx=v[2].toDoubleOrNull();if(rx!=null&&tx!=null){val old=interfaces[v[0]];val valid=timed&&old!=null&&rx>=old[0]&&tx>=old[1];network.put(obj("name" to v[0],"rxPerSecond" to if(valid)(rx-old!![0])/elapsed!! else JSONObject.NULL,"txPerSecond" to if(valid)(tx-old!![1])/elapsed!! else JSONObject.NULL));counters[v[0]]=listOf(rx,tx)}}
        }}
        time=now;cpu=raw;interfaces=counters
        val r=obj("os" to (values["OS"]?:"--"),"kernel" to (values["KERNEL"]?:"--"),"loadAverage" to (values["LOAD"]?:"--"),"swap" to (values["SWAP"]?:"--"),"uptime" to trf("{} 天 {} 小时",values["UPTIME_DAYS"]?:"--",values["UPTIME_HOURS"]?:"--"),"cpuCoreCount" to (n("CPU_CORES")?:0),"memoryTotal" to total*1048576,"memoryUsed" to (n("MEM_USED_MB")?:0.0)*1048576,"disks" to disks,"networkInterfaces" to network,"topMemoryProcesses" to tops,"cpuUsage" to (usage?:JSONObject.NULL),"cpuUserUsage" to (user?:JSONObject.NULL),"cpuSystemUsage" to (system?:JSONObject.NULL))
        val rows=(0 until network.length()).map{network.getJSONObject(it)}
        if(rows.any{it.metric("rxPerSecond")!=null}){r.put("networkRxPerSecond",rows.sumOf{it.metric("rxPerSecond")?:0.0});r.put("networkTxPerSecond",rows.sumOf{it.metric("txPerSecond")?:0.0})}
        return r
    }
    companion object{
        const val processCommand="LC_ALL=C ps -eo pid= -o user= -o pcpu= -o pmem= -o rss= -o comm="
        fun processes(output:String):List<JSONObject> = output.lineSequence().mapNotNull{line->val c=line.trim().split(Regex("\\s+"),limit=6);if(c.size==6&&c[0].toLongOrNull()!=null&&c[2].toDoubleOrNull()!=null)obj("pid" to c[0].toLong(),"user" to c[1],"cpuPercent" to c[2].toDouble(),"memPercent" to (c[3].toDoubleOrNull()?:0.0),"rssKB" to (c[4].toDoubleOrNull()?:0.0),"command" to c[5])else null}.toList()
    }
}
