package com.termpilot.app
import android.content.Context
import org.json.JSONObject

object MobileLanguage {
 var selection="zh-Hans"
 private var english=JSONObject()
 fun load(context:Context) {
  selection=context.getSharedPreferences("TermPilot",0).getString("language","zh-Hans")?:"zh-Hans"
  english=JSONObject(context.assets.open("MobileEnglish.json").bufferedReader().use{it.readText()})
 }
 fun translate(label:String):String {
  val enabled=selection=="en"||(selection=="system"&&java.util.Locale.getDefault().language!="zh")
  return if(enabled)english.optString(label,label)else label
 }
}
/** Translate application labels only; server output and user text stay verbatim. */
fun tr(label:String)=MobileLanguage.translate(label)

fun trf(template:String,vararg values:String):String {
 val parts=tr(template).split("{}")
 if(parts.size!=values.size+1)return tr(template)
 return parts.mapIndexed{index,part->part+values.getOrElse(index){""}}.joinToString("")
}
