package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

data class TerminalKey(val name:String,val text:String,val code:Int,val modifier:Int?=null) {
 companion object {
  const val defaultOrder="Esc,Tab,Ctrl-C,↑,↓,←,→"
  val all=listOf(
   TerminalKey("Esc","\u001b",0xff1b),TerminalKey("Tab","\t",0xff09),TerminalKey("Ctrl-C","\u0003",99,0xffe3),
   TerminalKey("↑","\u001b[A",0xff52),TerminalKey("↓","\u001b[B",0xff54),TerminalKey("←","\u001b[D",0xff51),TerminalKey("→","\u001b[C",0xff53),
   TerminalKey("Home","\u001b[H",0xff50),TerminalKey("End","\u001b[F",0xff57),TerminalKey("PgUp","\u001b[5~",0xff55),TerminalKey("PgDn","\u001b[6~",0xff56),TerminalKey("Delete","\u001b[3~",0xffff)
  )+(1..12).map{n->TerminalKey("F$n",if(n<=4)"\u001bO"+(79+n).toChar() else "\u001b[${listOf(15,17,18,19,20,21,23,24)[n-5]}~",0xffbd+n)}
  fun ordered(value:String)=value.split(',').distinct().mapNotNull{name->all.find{it.name==name}}
 }
}
@Composable fun KeyPreferencesDialog(model:AppModel,dismiss:()->Unit) {
 val selected=TerminalKey.ordered(model.keyOrder)
 fun move(index:Int,direction:Int){val names=selected.map{it.name}.toMutableList();val name=names.removeAt(index);names.add(index+direction,name);model.setKeys(names.joinToString(","))}
 FormPage(onDismissRequest=dismiss,title={Text(tr("快捷键栏"))},text={LazyColumn(verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
  item{GroupedSection{selected.forEachIndexed{index,key->Row(Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).padding(horizontal=MobileDesign.rowInset),verticalAlignment=androidx.compose.ui.Alignment.CenterVertically){Text(key.name,Modifier.weight(1f));TextButton(onClick={move(index,-1)},enabled=index>0,contentPadding=PaddingValues(4.dp)){Text("↑")};TextButton(onClick={move(index,1)},enabled=index<selected.lastIndex,contentPadding=PaddingValues(4.dp)){Text("↓")};TextButton(onClick={model.setKeys(selected.filter{it!=key}.joinToString(","){it.name})},contentPadding=PaddingValues(4.dp)){Text(tr("移除"))}}}
  }}
  item{GroupedSection("添加按键"){TerminalKey.all.filter{it !in selected}.forEachIndexed{index,key->if(index>0)GroupDivider();TextButton(onClick={model.setKeys((selected+key).joinToString(","){it.name})},modifier=Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight)){Text("+ ${key.name}",Modifier.fillMaxWidth().padding(horizontal=8.dp))}}}}
 }},confirmButton={TextButton(onClick=dismiss){Text(tr("完成"))}},dismissButton={TextButton(onClick={model.setKeys(TerminalKey.defaultOrder)}){Text(tr("恢复默认"))}})
}
