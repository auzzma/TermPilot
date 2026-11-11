package com.termpilot.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.*
import androidx.compose.ui.unit.dp

private data class MarkdownBlock(val kind:String,val text:String,val rows:List<List<String>> = emptyList())
@Composable fun MarkdownView(text:String){
    val context=LocalContext.current
    val blocks=remember(text){val lines=text.lines();var index=0;buildList{
        while(index<lines.size){val line=lines[index++]
            if(line.startsWith("```")){val code=mutableListOf<String>();while(index<lines.size&&!lines[index].startsWith("```"))code.add(lines[index++]);if(index<lines.size)index++;add(MarkdownBlock("code",code.joinToString("\n")))}
            else if('|' in line&&index<lines.size&&"---" in lines[index]&&lines[index].all{it in "| :-\t"}){
                fun cells(s:String)=s.trim().trim('|').split('|').map{it.trim()}
                val rows=mutableListOf(cells(line));index++;while(index<lines.size&&'|' in lines[index])rows.add(cells(lines[index++]));add(MarkdownBlock("table","",rows))
            }else if(line.isNotBlank())add(MarkdownBlock(if(line.startsWith('#'))"heading"else"text",line))
        }
    }}
    Column(verticalArrangement=Arrangement.spacedBy(10.dp)){
        blocks.forEach{block->when(block.kind){
            "code"->Surface(shape=RoundedCornerShape(12.dp),color=MaterialTheme.colorScheme.surfaceContainerHigh){Column(Modifier.padding(12.dp)){
                Row{Text(tr("代码"),Modifier.weight(1f),style=MaterialTheme.typography.labelMedium);IconButton(onClick={(context.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager).setPrimaryClip(android.content.ClipData.newPlainText("TermPilot",block.text))}){Icon(Icons.Outlined.ContentCopy,tr("复制代码"))}}
                SelectionContainer{Text(block.text,Modifier.horizontalScroll(rememberScrollState()),fontFamily=FontFamily.Monospace,style=MaterialTheme.typography.bodySmall)}
            }}
            "table"->Row(Modifier.horizontalScroll(rememberScrollState())){Column{
                block.rows.forEachIndexed{index,cells->Row{cells.forEachIndexed{col,cell->
                    val width=(block.rows.maxOfOrNull{it.getOrNull(col)?.length?:0}?:12).times(8).coerceIn(100,240).dp
                    SelectionContainer{Text(inlineMarkdown(cell),Modifier.width(width).border(.5.dp,MaterialTheme.colorScheme.outlineVariant).padding(10.dp),fontWeight=if(index==0)FontWeight.SemiBold else FontWeight.Normal)}
                }}}
            }}
            "heading"->SelectionContainer{Text(block.text.trimStart('#',' '),style=MaterialTheme.typography.titleMedium)}
            else->SelectionContainer{val line=block.text.trim();Text(inlineMarkdown(if(line.startsWith("- ")||line.startsWith("* "))"• "+line.drop(2)else line))}
        }}
    }
}
private fun inlineMarkdown(text:String):AnnotatedString=buildAnnotatedString{
    val tokens=Regex("(\\*\\*(.+?)\\*\\*|`([^`]+)`)");var start=0
    for(match in tokens.findAll(text)){append(text.substring(start,match.range.first));val code=match.groupValues[3];withStyle(if(code.isNotEmpty())SpanStyle(fontFamily=FontFamily.Monospace)else SpanStyle(fontWeight=FontWeight.SemiBold)){append(code.ifEmpty{match.groupValues[2]})};start=match.range.last+1}
    append(text.substring(start))
}
