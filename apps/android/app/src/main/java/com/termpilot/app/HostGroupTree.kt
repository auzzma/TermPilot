package com.termpilot.app

/** A defensive view of existing parentGroupID relationships; never rewrites synced data. */
internal data class HostGroupInfo(val id:String,val name:String,val parent:String="",val order:Int=0)
internal data class HostGroupNode(val group:HostGroupInfo,val children:List<HostGroupNode>){
    fun descendants():Set<String> = setOf(group.id)+children.flatMap{it.descendants()}
}
internal fun hostGroupTree(groups:List<HostGroupInfo>):List<HostGroupNode>{
    val sorted=groups.filter{it.id.isNotBlank()}.distinctBy{it.id}.sortedWith(compareBy<HostGroupInfo>{it.order}.thenBy{it.name.lowercase()})
    val known=sorted.map{it.id}.toSet();val visited=mutableSetOf<String>()
    fun node(group:HostGroupInfo):HostGroupNode{
        visited.add(group.id)
        return HostGroupNode(group,sorted.filter{it.parent==group.id&&!visited.contains(it.id)}.mapNotNull{if(it.id in visited)null else node(it)})
    }
    val roots=mutableListOf<HostGroupNode>()
    for(group in sorted.filter{it.parent !in known})if(group.id !in visited)roots+=node(group)
    // Imported orphan/cyclic data remains reachable instead of disappearing.
    for(group in sorted)if(group.id !in visited)roots+=node(group)
    return roots
}
internal fun hostGroupOptions(nodes:List<HostGroupNode>,prefix:String=""):List<Pair<String,String>> = nodes.flatMap{
    val path=if(prefix.isEmpty())it.group.name else "$prefix / ${it.group.name}"
    listOf(it.group.id to path)+hostGroupOptions(it.children,path)
}
internal data class HostTreeRow(val id:String,val depth:Int,val group:HostGroupNode?=null,val hostID:String?=null,val count:Int=0,val expanded:Boolean=false)
internal fun hostTreeRows(roots:List<HostGroupNode>,hosts:Map<String,List<Pair<String,String>>>,collapsed:Set<String>,search:String):List<HostTreeRow>{
    val rows=mutableListOf<HostTreeRow>();val query=search.trim()
    fun count(node:HostGroupNode):Int=(hosts[node.group.id]?.size?:0)+node.children.sumOf{count(it)}
    fun matches(node:HostGroupNode):Boolean=node.group.name.contains(query,true)||hosts[node.group.id].orEmpty().any{it.second.contains(query,true)}||node.children.any{matches(it)}
    fun append(node:HostGroupNode,depth:Int,parentMatches:Boolean){
        val all=parentMatches||(query.isNotEmpty()&&node.group.name.contains(query,true))
        if(query.isNotEmpty()&&!all&&!matches(node))return
        val expanded=query.isNotEmpty()||node.group.id !in collapsed
        rows+=HostTreeRow("group-"+node.group.id,depth,node,count=count(node),expanded=expanded)
        if(expanded){
            for(child in node.children)append(child,depth+1,all)
            for((id,text)in hosts[node.group.id].orEmpty())if(query.isEmpty()||all||text.contains(query,true))rows+=HostTreeRow("host-$id",depth+1,hostID=id)
        }
    }
    roots.forEach{append(it,0,false)}
    return rows
}
