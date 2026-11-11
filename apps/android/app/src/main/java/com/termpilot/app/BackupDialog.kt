package com.termpilot.app

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.text.input.PasswordVisualTransformation
import java.io.File
import java.util.UUID

@Composable fun BackupDialog(model:AppModel,dismiss:()->Unit) {
    var password by remember{mutableStateOf("")}
    var exporting by remember{mutableStateOf<File?>(null)}
    var status by remember{mutableStateOf("")}
    val export=rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")){uri->exporting?.let{file->if(uri!=null)model.launch{model.exportFile(file,uri);status=tr("备份已导出")}}}
    val picker=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()){uri->if(uri!=null)model.launch{
        val staged=model.importFile(uri)
        try{
            val previous=File(model.runtime!!.directory,"before-import-${UUID.randomUUID()}.backup")
            model.call(obj("method" to "vault.export","path" to previous.path,"password" to password))
            model.call(obj("method" to "vault.import","path" to staged.path,"password" to password));model.reload()
            status=tr("导入完成，请保存导入前的备份");exporting=previous;export.launch("TermPilot-before-import.backup")
        }finally{staged.delete()}
    }}
    FormPage(onDismissRequest=dismiss,title={Text(tr("备份与恢复"))},text={Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(MobileDesign.sectionGap)){
        GroupedSection("跨设备备份",footer="使用与桌面版相同的加密备份格式。导入前会自动备份当前数据。"){
        SettingField(password,{password=it},label=tr("备份密码"),visualTransformation=PasswordVisualTransformation())
        }
        GroupedSection{TextButton(modifier=Modifier.fillMaxWidth(),enabled=password.isNotEmpty(),onClick={model.launch{val file=File(model.runtime!!.directory,"TermPilot-${UUID.randomUUID()}.backup");model.call(obj("method" to "vault.export","path" to file.path,"password" to password));exporting=file;export.launch("TermPilot.backup")}}){Text(tr("导出加密备份"))};GroupDivider()
        TextButton(modifier=Modifier.fillMaxWidth(),enabled=password.isNotEmpty(),onClick={picker.launch(arrayOf("*/*"))}){Text(tr("导入备份"))}
        }
        if(status.isNotEmpty())Text(status)
    }},confirmButton={TextButton(onClick=dismiss){Text(tr("完成"))}})
}
