package com.termpilot.app
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
@Composable fun TerminalSearch(model:AppModel,s:Session){
 var text by remember{mutableStateOf("")};var query by remember{mutableStateOf("")}
 LaunchedEffect(s.id){model.launch{val lines=mutableListOf<String>();var start=0;while(start<10000){val p=model.call(obj("method" to "terminal.context","id" to s.terminal,"range" to "lines","startLine" to start,"maxLines" to 300));lines.add(p.optString("text"));val next=p.optInt("nextLine");if(next<=start||next>=p.optInt("totalLines"))break;start=next};text=lines.joinToString("\n")}}
 AlertDialog(onDismissRequest={s.searchTerminal=false},title={Text(tr("选择与搜索"))},text={Column{
  OutlinedTextField(query,{query=it},label={Text(tr("搜索终端历史"))},singleLine=true)
  SelectionContainer{Text(if(query.isEmpty())text else text.lineSequence().filter{it.contains(query,true)}.joinToString("\n"),Modifier.padding(top=12.dp).verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall)}
 }},confirmButton={TextButton(onClick={s.searchTerminal=false}){Text(tr("完成"))}})
}
