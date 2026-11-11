package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import org.json.JSONObject

@Composable fun AgentForm(spec:JSONObject,values:JSONObject,change:(JSONObject)->Unit) {
    LaunchedEffect(spec.toString()){
        val next=JSONObject(values.toString())
        spec.objects("fields").forEach{field->val name=field.getString("name");if(!next.has(name))next.put(name,spec.optJSONObject("values")?.opt(name)?:field.opt("default"))}
        change(next)
    }
    Text(spec.optString("title",tr("填写信息")),style=MaterialTheme.typography.titleMedium)
    if(spec.optString("error").isNotEmpty())Text(spec.optString("error"),color=MaterialTheme.colorScheme.error)
    spec.objects("fields").forEach{field->
        val name=field.getString("name");val kind=field.optString("type");val c=field.optJSONObject("visibleWhen")
        val v=c?.let{values.opt(it.optString("field"))};val truth=v!=null&&v!=JSONObject.NULL&&v!=false&&v.toString()!="0"&&v.toString().isNotEmpty()
        val visible=c==null||when{c.has("equals")->v==c.opt("equals");c.has("notEquals")->v!=c.opt("notEquals");c.optBoolean("falsy")->!truth;else->truth}
        fun update(value:Any){change(JSONObject(values.toString()).put(name,value))}
        if(visible){val label=field.optString("label",name)+(if(field.optBoolean("required"))" *" else "")
            when(kind){
                "checkbox"->Row{Checkbox(values.optBoolean(name),{update(it)});Text(label,Modifier.padding(top=12.dp))}
                "select","radio"->Choice(label,values.optString(name),field.objects("options").map{it.optString("value") to it.optString("label")}){update(it)}
                else->OutlinedTextField(values.opt(name)?.takeUnless{it==JSONObject.NULL}?.toString()?:"",{update(it)},label={Text(tr(label))},modifier=Modifier.fillMaxWidth(),minLines=if(kind=="textarea")3 else 1,maxLines=if(kind=="textarea")10 else 1,visualTransformation=if(kind=="password")PasswordVisualTransformation()else VisualTransformation.None)
            }
        }
    }
}
