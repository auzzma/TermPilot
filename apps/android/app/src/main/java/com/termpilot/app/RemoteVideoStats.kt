package com.termpilot.app

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/** Tap the existing FPS strip for non-sensitive reception/rendering diagnostics. */
@Composable internal fun RemoteVideoStats(session:Session) {
    var show by remember(session.id){mutableStateOf(false)}
    Row(Modifier.fillMaxWidth().clickable(onClickLabel=tr("画面诊断")){show=true}.padding(horizontal=12.dp,vertical=4.dp)){
        Text("%.1f FPS · ".format(session.renderedFPS),style=MaterialTheme.typography.labelSmall)
        Text("↓ ${session.stats.optLong("receiveBytesPerSecond")/1024} KiB/s",style=MaterialTheme.typography.labelSmall)
        Spacer(Modifier.weight(1f))
        Text("↑ ${session.stats.optLong("sendBytesPerSecond")/1024} KiB/s",style=MaterialTheme.typography.labelSmall)
    }
    if(show){
        val context=LocalContext.current
        val build=remember{context.packageManager.getPackageInfo(context.packageName,0).longVersionCode}
        var now by remember{mutableLongStateOf(System.nanoTime())}
        LaunchedEffect(session.id){while(true){delay(500);now=System.nanoTime()}}
        fun age(at:Long)=if(at==0L)tr("暂无")else "%.1f s".format((now-at).coerceAtLeast(0)/1e9)
        val text=buildString{
            appendLine("TermPilot · build $build · ${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            appendLine("${session.protocol} / ${session.host.optString("mode","standardVNC")}")
            appendLine("${tr("接收画面")}: ${session.frameRevision} · ${age(session.lastFrameAt)}")
            appendLine("${tr("绘制画面")}: ${session.renderedFrames} · ${age(session.lastRenderedAt)}")
            appendLine("${tr("画面错误")}: ${session.videoError.ifEmpty{tr("无")}}")
            appendLine(session.rendererInfo)
            val media=session.mediaDiagnostics
            if(media.has("videoPackets")){
                appendLine("Video codec: ${media.optString("videoCodec","—")}")
                if(media.optString("nativeDecoder").isNotEmpty()){
                    appendLine("Decoder: ${media.optString("nativeDecoder")} · Color: ${media.optLong("nativeColorFormat")}")
                    appendLine("Current decoder input/output: ${media.optLong("nativeSubmitted")} / ${media.optLong("nativeOutputs")}")
                }
                appendLine("Video packets: ${media.optLong("videoPackets")}")
                appendLine("Decoded: ${media.optLong("frames")} · Decode errors: ${media.optLong("decodeErrors")} · Dropped: ${media.optLong("dropped")}")
                appendLine("Receive queue drops: ${media.optLong("receiveQueueDrops")} packets · Assembly queue drops: ${media.optLong("decodeQueueDrops")} packets")
                appendLine("Oversized packets: ${media.optLong("oversizedPackets")}")
                appendLine("Assembly expired: ${media.optLong("assemblyDrops")} units · Late units: ${media.optLong("lateUnits")} · Missing sequence: ${media.optLong("missingUnits")}")
                appendLine("Codec queue drops: ${media.optLong("codecQueueDrops")} units · Recovery skips: ${media.optLong("recoverySkips")}")
                appendLine("Overload recoveries: ${media.optLong("overloadRecoveries")} · Decoder resets: ${media.optLong("decoderResets")}")
                val calls=media.optLong("decodeCalls").coerceAtLeast(1)
                appendLine("Decode time: %.2f ms avg · %.2f ms max · Queue wait: %.2f ms max".format(media.optLong("decodeMicros")/calls/1000.0,media.optLong("maxDecodeMicros")/1000.0,media.optLong("maxQueueMicros")/1000.0))
                appendLine("Video errors: ${(media.optLong("decodeErrors")-media.optLong("audioDecodeErrors")).coerceAtLeast(0)} · Last code: ${media.optInt("lastVideoDecodeError")} · Audio errors: ${media.optLong("audioDecodeErrors")}")
            }
        }.trim()
        AlertDialog(onDismissRequest={show=false},title={Text(tr("画面诊断"))},
            text={Column(Modifier.verticalScroll(rememberScrollState())){Text(text,style=MaterialTheme.typography.bodySmall)}},
            confirmButton={TextButton(onClick={show=false}){Text(tr("完成"))}},
            dismissButton={TextButton(onClick={(context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("TermPilot video diagnostics",text))}){Text(tr("复制"))}})
    }
}
