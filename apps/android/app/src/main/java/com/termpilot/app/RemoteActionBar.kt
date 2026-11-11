package com.termpilot.app

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

internal enum class RemoteAction { Touchpad, Keyboard, Paste, Copy, Drag, ScrollUp, ScrollDown, SystemKey, Audio }

/** All remote protocols share the same ordering, button style and toggle states. */
@Composable internal fun RemoteActionBar(
    touchpad:Boolean,
    keyboard:Boolean,
    dragLocked:Boolean,
    audioEnabled:Boolean,
    shortcuts:List<TerminalKey>,
    onAction:(RemoteAction)->Unit,
    onShortcut:(TerminalKey)->Unit
) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(6.dp),
        horizontalArrangement=Arrangement.spacedBy(6.dp),
        verticalAlignment=Alignment.CenterVertically
    ) {
        RemoteActionButton(tr("触控板"),{onAction(RemoteAction.Touchpad)},active=touchpad)
        RemoteActionButton(tr("键盘"),{onAction(RemoteAction.Keyboard)},active=keyboard)
        RemoteActionButton(tr("粘贴"),{onAction(RemoteAction.Paste)})
        RemoteActionButton(tr("复制远端"),{onAction(RemoteAction.Copy)})

        RemoteActionDivider()
        RemoteActionButton(tr("拖动锁定"),{onAction(RemoteAction.Drag)},active=dragLocked)
        RemoteActionButton(tr("滚动↑"),{onAction(RemoteAction.ScrollUp)})
        RemoteActionButton(tr("滚动↓"),{onAction(RemoteAction.ScrollDown)})

        RemoteActionDivider()
        RemoteActionButton("Win/⌘",{onAction(RemoteAction.SystemKey)})
        shortcuts.forEach{item->RemoteActionButton(item.name,{onShortcut(item)})}

        RemoteActionDivider()
        RemoteActionButton(tr("声音"),{onAction(RemoteAction.Audio)},active=audioEnabled)
    }
}

@Composable private fun RemoteActionDivider() {
    VerticalDivider(Modifier.padding(horizontal=4.dp).height(22.dp),color=MaterialTheme.colorScheme.outlineVariant)
}

@Composable internal fun RemoteActionButton(
    label:String,
    onClick:()->Unit,
    modifier:Modifier=Modifier,
    active:Boolean?=null
) {
    val colors=MaterialTheme.colorScheme
    OutlinedButton(
        onClick=onClick,
        modifier=modifier.heightIn(min=44.dp).then(if(active!=null)Modifier.semantics{selected=active}else Modifier),
        border=BorderStroke(1.dp,if(active==true)colors.primary else colors.outline),
        colors=ButtonDefaults.outlinedButtonColors(containerColor=if(active==true)colors.primaryContainer else Color.Transparent),
        contentPadding=PaddingValues(horizontal=12.dp,vertical=6.dp)
    ){Text(label,maxLines=1)}
}
