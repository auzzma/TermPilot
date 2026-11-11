package com.termpilot.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat

private val mobileTypography = Typography(
    headlineLarge=TextStyle(fontSize=34.sp,lineHeight=41.sp,fontWeight=FontWeight.Bold),
    headlineMedium=TextStyle(fontSize=28.sp,lineHeight=34.sp,fontWeight=FontWeight.Bold),
    titleLarge=TextStyle(fontSize=22.sp,lineHeight=28.sp,fontWeight=FontWeight.SemiBold),
    titleMedium=TextStyle(fontSize=17.sp,lineHeight=22.sp,fontWeight=FontWeight.SemiBold),
    titleSmall=TextStyle(fontSize=15.sp,lineHeight=20.sp,fontWeight=FontWeight.SemiBold),
    bodyLarge=TextStyle(fontSize=17.sp,lineHeight=22.sp),
    bodyMedium=TextStyle(fontSize=15.sp,lineHeight=20.sp),
    bodySmall=TextStyle(fontSize=13.sp,lineHeight=18.sp),
    labelLarge=TextStyle(fontSize=17.sp,lineHeight=22.sp,fontWeight=FontWeight.Medium),
    labelMedium=TextStyle(fontSize=13.sp,lineHeight=18.sp),
    labelSmall=TextStyle(fontSize=11.sp,lineHeight=14.sp)
)

@Composable fun MobileTheme(dark:Boolean,content:@Composable ()->Unit) {
    val colors=if(dark) darkColorScheme(
        primary=MobileDesign.Dark.accent,onPrimary=Color.White,primaryContainer=MobileDesign.Dark.accent.copy(alpha=.13f),
        background=MobileDesign.Dark.background,onBackground=MobileDesign.Dark.label,
        surface=MobileDesign.Dark.surface,onSurface=MobileDesign.Dark.label,
        surfaceContainer=MobileDesign.Dark.surface,surfaceContainerHigh=MobileDesign.Dark.elevated,surfaceContainerHighest=MobileDesign.Dark.secondary,
        onSurfaceVariant=MobileDesign.Dark.secondaryLabel,outline=MobileDesign.Dark.gray,outlineVariant=MobileDesign.Dark.separator,error=MobileDesign.Dark.red
    ) else lightColorScheme(
        primary=MobileDesign.Light.accent,onPrimary=Color.White,primaryContainer=MobileDesign.Light.accent.copy(alpha=.13f),
        background=MobileDesign.Light.background,onBackground=MobileDesign.Light.label,
        surface=MobileDesign.Light.surface,onSurface=MobileDesign.Light.label,
        surfaceContainer=MobileDesign.Light.surface,surfaceContainerHigh=MobileDesign.Light.elevated,surfaceContainerHighest=MobileDesign.Light.secondary,
        onSurfaceVariant=MobileDesign.Light.secondaryLabel,outline=MobileDesign.Light.gray,outlineVariant=MobileDesign.Light.separator,error=MobileDesign.Light.red
    )
    MaterialTheme(colorScheme=colors,typography=mobileTypography,shapes=Shapes(small=RoundedCornerShape(8.dp),medium=RoundedCornerShape(12.dp),large=RoundedCornerShape(18.dp),extraLarge=RoundedCornerShape(MobileDesign.sectionRadius)),content=content)
}

/** Keep the monitor's original theme, typography, shapes, cards and graphs. */
@Composable fun MonitorAppearance(model:AppModel,content:@Composable ()->Unit) {
    val dark=when(model.theme){"light"->false;"system"->isSystemInDarkTheme();else->true}
    MaterialTheme(colorScheme=if(dark)darkColorScheme(primary=Color(0xff65a9ff),background=Color(0xff17191f),surface=Color(0xff20232b))else lightColorScheme(primary=Color(0xff0877df)),typography=Typography(),shapes=Shapes()){
        Surface(Modifier.fillMaxSize(),color=MaterialTheme.colorScheme.surface,content=content)
    }
}

@Composable fun GroupedSection(title:String="",footer:String="",content:@Composable ColumnScope.()->Unit) {
    Column(Modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(10.dp)) {
        if(title.isNotEmpty())Text(tr(title),Modifier.padding(horizontal=MobileDesign.rowInset),style=MaterialTheme.typography.titleMedium,color=MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(Modifier.fillMaxWidth(),color=MaterialTheme.colorScheme.surface,shape=RoundedCornerShape(MobileDesign.sectionRadius)){Column(content=content)}
        if(footer.isNotEmpty())Text(tr(footer),Modifier.padding(horizontal=MobileDesign.rowInset),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable private fun categoryColor(title:String):Color = when(title){
    "AI","提供商","代理配置","备份与恢复"->MaterialTheme.colorScheme.primary
    "凭证与密钥","快速连接","工具接入"->MobileDesign.Dark.orange
    "工具与快捷键","Agent"->MobileDesign.Dark.purple
    "传输记录","行为与安全"->MobileDesign.Dark.green
    "网络搜索"->MobileDesign.Dark.cyan
    else->MobileDesign.Dark.gray
}

@Composable fun SettingRow(title:String,icon:ImageVector?=null,value:String="",subtitle:String="",onClick:(()->Unit)?=null,chevron:Boolean=true) {
    Row(Modifier.fillMaxWidth().heightIn(min=if(icon!=null)MobileDesign.iconRowHeight else MobileDesign.rowHeight)
        .then(if(onClick!=null)Modifier.clickable(onClick=onClick)else Modifier)
        .padding(horizontal=MobileDesign.rowInset,vertical=10.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
        if(icon!=null)Surface(Modifier.size(MobileDesign.iconTile),shape=RoundedCornerShape(MobileDesign.iconRadius),color=categoryColor(title)){
            Box(contentAlignment=Alignment.Center){Icon(icon,null,Modifier.size(MobileDesign.iconSize),tint=Color.White)}
        }
        Column(Modifier.weight(1f),verticalArrangement=Arrangement.spacedBy(3.dp)){
            Text(tr(title),style=MaterialTheme.typography.bodyLarge)
            if(subtitle.isNotEmpty())Text(subtitle,style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if(value.isNotEmpty())Text(value,Modifier.widthIn(max=180.dp),maxLines=2,overflow=TextOverflow.Ellipsis,style=MaterialTheme.typography.bodyLarge,color=MaterialTheme.colorScheme.onSurfaceVariant)
        if(onClick!=null&&chevron)Icon(Icons.Outlined.ChevronRight,null,Modifier.size(18.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable fun GroupDivider(inset:androidx.compose.ui.unit.Dp=MobileDesign.rowInset){HorizontalDivider(Modifier.padding(start=inset,end=MobileDesign.rowInset),thickness=.5.dp,color=MaterialTheme.colorScheme.outlineVariant)}

/** Plain native editable row. The accessible label remains available after typing. */
@Composable fun SettingField(value:String,onValueChange:(String)->Unit,label:String="",modifier:Modifier=Modifier,singleLine:Boolean=true,minLines:Int=1,maxLines:Int=Int.MAX_VALUE,visualTransformation:VisualTransformation=VisualTransformation.None,textStyle:TextStyle=MaterialTheme.typography.bodyLarge,placeholder:@Composable (()->Unit)?=null,leadingIcon:@Composable (()->Unit)?=null){
    Column(modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).padding(horizontal=MobileDesign.rowInset,vertical=14.dp)){
        if(minLines>1&&label.isNotBlank())Text(label,Modifier.padding(bottom=8.dp),style=MaterialTheme.typography.bodySmall,color=MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){
            if(leadingIcon!=null)CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant){leadingIcon()}
            BasicTextField(value,onValueChange,Modifier.weight(1f).semantics{if(label.isNotBlank())contentDescription=label},
                textStyle=textStyle.merge(TextStyle(color=MaterialTheme.colorScheme.onSurface)),
                singleLine=singleLine&&minLines==1,minLines=minLines,maxLines=if(singleLine&&minLines==1)1 else maxLines,
                visualTransformation=visualTransformation,cursorBrush=SolidColor(MaterialTheme.colorScheme.primary),
                decorationBox={inner->Box{
                    if(value.isEmpty())CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurfaceVariant){
                        if(placeholder!=null)placeholder()else if(minLines==1)Text(label,style=MaterialTheme.typography.bodyLarge)
                    }
                    inner()
                }})
        }
    }
}

@Composable fun MobileSearchField(value:String,onValueChange:(String)->Unit,hint:String,modifier:Modifier=Modifier){
    Surface(modifier.fillMaxWidth(),color=MaterialTheme.colorScheme.surfaceContainerHighest.copy(alpha=.65f),shape=RoundedCornerShape(12.dp)){
        Row(Modifier.padding(horizontal=12.dp,vertical=9.dp),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(8.dp)){
            Icon(Icons.Outlined.Search,null,Modifier.size(19.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)
            BasicTextField(value,onValueChange,Modifier.weight(1f).semantics{contentDescription=hint},singleLine=true,
                textStyle=MaterialTheme.typography.bodyLarge.copy(color=MaterialTheme.colorScheme.onSurface),cursorBrush=SolidColor(MaterialTheme.colorScheme.primary),
                decorationBox={inner->Box{if(value.isEmpty())Text(hint,color=MaterialTheme.colorScheme.onSurfaceVariant);inner()}})
            if(value.isNotEmpty())Box(Modifier.size(24.dp).clickable{onValueChange("")},contentAlignment=Alignment.Center){Icon(Icons.Outlined.Cancel,tr("清除"),Modifier.size(18.dp),tint=MaterialTheme.colorScheme.onSurfaceVariant)}
        }
    }
}

@Composable fun MobileNavigationHeader(title:@Composable ()->Unit,onBack:(()->Unit)?=null,backLabel:String=tr("返回"),backTag:String="",actions:@Composable RowScope.()->Unit={}){
    Row(Modifier.fillMaxWidth().heightIn(min=56.dp).padding(horizontal=8.dp),verticalAlignment=Alignment.CenterVertically){
        Box(Modifier.weight(1f),contentAlignment=Alignment.CenterStart){if(onBack!=null)TextButton(onClick=onBack,modifier=Modifier.then(if(backTag.isNotEmpty())Modifier.testTag(backTag)else Modifier).semantics{contentDescription=backLabel}){if(backLabel!=tr("取消"))Icon(Icons.Outlined.ChevronLeft,null,Modifier.size(24.dp));Text(backLabel,maxLines=1)}}
        Box(Modifier.weight(2f),contentAlignment=Alignment.Center){ProvideTextStyle(MaterialTheme.typography.titleMedium){title()}}
        Row(Modifier.weight(1f),horizontalArrangement=Arrangement.End,verticalAlignment=Alignment.CenterVertically,content=actions)
    }
}
@Composable fun LargePageTitle(title:String,actions:@Composable RowScope.()->Unit={}){
    Column(Modifier.fillMaxWidth()){
        Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal=8.dp),horizontalArrangement=Arrangement.End,verticalAlignment=Alignment.CenterVertically,content=actions)
        Text(tr(title),Modifier.padding(start=MobileDesign.pageInset,end=MobileDesign.pageInset,bottom=16.dp),style=MaterialTheme.typography.headlineLarge)
    }
}

@Composable fun MobileToggle(title:String,checked:Boolean,onCheckedChange:(Boolean)->Unit){
    Row(Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).padding(horizontal=MobileDesign.rowInset),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
        Text(tr(title),Modifier.weight(1f))
        Switch(checked,onCheckedChange,Modifier.semantics{contentDescription=tr(title)},colors=SwitchDefaults.colors(checkedTrackColor=MobileDesign.Dark.green,checkedThumbColor=Color.White,uncheckedTrackColor=MaterialTheme.colorScheme.surfaceContainerHighest,uncheckedThumbColor=Color.White,uncheckedBorderColor=Color.Transparent))
    }
}

@Composable fun MobileSegments(options:List<Pair<String,String>>,selected:String,onSelect:(String)->Unit,tagPrefix:String="",modifier:Modifier=Modifier){
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceContainerHighest).padding(3.dp)){
        options.forEach{(key,label)->val active=selected==key
            Box(Modifier.weight(1f).clip(RoundedCornerShape(8.dp)).background(if(active)MaterialTheme.colorScheme.surface else Color.Transparent)
                .then(if(tagPrefix.isNotEmpty())Modifier.testTag(tagPrefix+key)else Modifier).selectable(active,role=Role.Tab){onSelect(key)}.heightIn(min=32.dp).padding(6.dp),contentAlignment=Alignment.Center){
                Text(tr(label),style=MaterialTheme.typography.bodySmall,fontWeight=if(active)FontWeight.SemiBold else FontWeight.Normal,maxLines=1)
            }
        }
    }
}

data class MobileTab(val key:String,val title:String,val icon:ImageVector)
@Composable fun MobileTabBar(tabs:List<MobileTab>,selected:String,choose:(String)->Unit,tagPrefix:String){
    Box(Modifier.fillMaxWidth().padding(horizontal=24.dp,vertical=8.dp),contentAlignment=Alignment.Center){
        Surface(Modifier.widthIn(max=360.dp).fillMaxWidth(),shape=RoundedCornerShape(36.dp),color=MaterialTheme.colorScheme.surfaceContainerHigh,border=BorderStroke(.5.dp,MaterialTheme.colorScheme.outlineVariant)){
            Row(Modifier.padding(4.dp)){
                tabs.forEach{tab->val active=selected==tab.key
                    Column(Modifier.weight(1f).clip(RoundedCornerShape(30.dp)).background(if(active)MaterialTheme.colorScheme.surfaceContainerHighest else Color.Transparent)
                        .testTag(tagPrefix+tab.key).selectable(active,role=Role.Tab){choose(tab.key)}.heightIn(min=58.dp).padding(vertical=6.dp),
                        horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(3.dp)){
                        val tint=if(active)MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                        Icon(tab.icon,null,Modifier.size(24.dp),tint=tint)
                        Text(tr(tab.title),style=MaterialTheme.typography.labelSmall,color=tint,fontWeight=if(active)FontWeight.SemiBold else FontWeight.Normal)
                    }
                }
            }
        }
    }
}

/** Editors use the same grouped sheet hierarchy as iOS; Android retains its back gesture. */
@Composable fun FormPage(onDismissRequest:()->Unit,title:@Composable ()->Unit,text:@Composable ()->Unit,confirmButton:@Composable ()->Unit={},dismissButton:(@Composable ()->Unit)?=null,footer:(@Composable ()->Unit)?=null,editing:Boolean=false){
    Dialog(onDismissRequest,properties=DialogProperties(usePlatformDefaultWidth=false,decorFitsSystemWindows=false)){
        val view=LocalView.current
        val dark=MaterialTheme.colorScheme.background.luminance()<.5f
        SideEffect {(view.parent as? DialogWindowProvider)?.window?.let{window->WindowCompat.getInsetsController(window,view).apply{isAppearanceLightStatusBars=!dark;isAppearanceLightNavigationBars=!dark}}}
        BackHandler(onBack=onDismissRequest)
        val scheme=MaterialTheme.colorScheme
        val sheetColors=if(editing&&dark)scheme.copy(background=MobileDesign.Dark.surface,surface=MobileDesign.Dark.elevated)else scheme
        MaterialTheme(colorScheme=sheetColors){
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding().imePadding(),contentAlignment=Alignment.Center){
                val wide=maxWidth>=MobileDesign.wideBreakpoint
                Surface(Modifier.widthIn(max=if(wide)MobileDesign.formWidth else maxWidth).fillMaxWidth().fillMaxHeight(if(wide).9f else 1f)
                    .padding(top=if(editing&&!wide)16.dp else 0.dp),color=MaterialTheme.colorScheme.background,shape=RoundedCornerShape(if(editing||wide)28.dp else 0.dp)){
                    Column{
                        MobileNavigationHeader(title,onDismissRequest,if(editing)tr("取消")else tr("返回")){confirmButton()}
                        Box(Modifier.weight(1f).fillMaxWidth(),contentAlignment=Alignment.TopCenter){Box(Modifier.widthIn(max=MobileDesign.formWidth).fillMaxHeight().padding(horizontal=MobileDesign.pageInset,vertical=16.dp)){text()}}
                        if(dismissButton!=null)Row(Modifier.fillMaxWidth().padding(horizontal=16.dp,vertical=6.dp),horizontalArrangement=Arrangement.End){dismissButton()}
                        footer?.invoke()
                    }
                }
            }
        }
    }
}

@Composable fun MobileToolCard(content:@Composable ()->Unit){
    Surface(Modifier.fillMaxWidth(),color=MaterialTheme.colorScheme.surface,shape=RoundedCornerShape(MobileDesign.sectionRadius)){Box(Modifier.padding(MobileDesign.rowInset)){content()}}
}

/** Native step control, matching the labeled iOS settings row. */
@Composable fun MobileStepper(title:String,value:Int,range:IntRange,change:(Int)->Unit){
    Row(Modifier.fillMaxWidth().heightIn(min=MobileDesign.rowHeight).padding(horizontal=MobileDesign.rowInset),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
        Text(tr(title)+" "+value,Modifier.weight(1f))
        Surface(color=MaterialTheme.colorScheme.surfaceContainerHighest,shape=RoundedCornerShape(8.dp)){
            Row(verticalAlignment=Alignment.CenterVertically){
                IconButton(onClick={change(value-1)},enabled=value>range.first,modifier=Modifier.size(44.dp)){Icon(Icons.Outlined.Remove,tr(title)+" −",Modifier.size(18.dp))}
                Box(Modifier.width(.5.dp).height(20.dp).background(MaterialTheme.colorScheme.outlineVariant))
                IconButton(onClick={change(value+1)},enabled=value<range.last,modifier=Modifier.size(44.dp)){Icon(Icons.Outlined.Add,tr(title)+" +",Modifier.size(18.dp))}
            }
        }
    }
}

@Composable fun MobileWorkspaceTabs(tabs:List<MobileTab>,selected:String,choose:(String)->Unit){
    Row(Modifier.fillMaxWidth().padding(6.dp),horizontalArrangement=Arrangement.spacedBy(8.dp)){
        tabs.forEach{tab->val active=selected==tab.key
            Column(Modifier.weight(1f).clip(RoundedCornerShape(10.dp)).background(if(active)MaterialTheme.colorScheme.primary.copy(alpha=.16f)else Color.Transparent)
                .testTag("workspace-"+tab.key).selectable(active,role=Role.Tab){choose(tab.key)}.heightIn(min=48.dp).padding(7.dp),
                horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(3.dp)){
                Icon(tab.icon,null,Modifier.size(19.dp),tint=MaterialTheme.colorScheme.primary)
                Text(tr(tab.title),style=MaterialTheme.typography.labelSmall,color=MaterialTheme.colorScheme.primary)
            }
        }
    }
}
