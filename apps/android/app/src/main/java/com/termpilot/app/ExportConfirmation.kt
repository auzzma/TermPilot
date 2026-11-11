package com.termpilot.app

import android.system.Os
import android.system.OsConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

object AppleFileMetadata {
 fun needsConfirmation(root:File):Boolean {
  var count=0
  fun inspect(file:File):Boolean {
   if(++count>100000||java.nio.file.Files.isSymbolicLink(file.toPath()))return true
   for(name in listOf("user.com.apple.ResourceFork","user.com.apple.FinderInfo")) {
    try{if(Os.getxattr(file.path,name).isNotEmpty())return true}
    catch(e:android.system.ErrnoException){if(e.errno!=OsConstants.ENODATA)return true}
   }
   return file.isDirectory&&(file.listFiles()?.any{inspect(it)}?:true)
  }
  return inspect(root)
 }
}
@Composable fun rememberFileExport(model:AppModel):(File)->Unit {
 var exporting by remember{mutableStateOf<File?>(null)}
 var confirmation by remember{mutableStateOf<File?>(null)}
 val export=rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")){uri->val file=exporting;if(uri!=null&&file!=null)model.launch{model.exportFile(file,uri)}}
 val tree=rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()){uri->val file=exporting;if(uri!=null&&file!=null)model.launch{model.exportFolder(file,uri)}}
 fun perform(file:File){exporting=file;if(file.isDirectory)tree.launch(null)else export.launch(file.name)}
 confirmation?.let{file->AlertDialog(onDismissRequest={confirmation=null},title={Text(tr("此文件包含 Apple 附加信息"))},text={Text(tr("系统文件提供商无法保留资源分支或 Finder 信息。导出后文件内容可用，但相关 Apple 信息会丢失；应用内下载的原件会保留。"))},confirmButton={TextButton(onClick={confirmation=null;perform(file)}){Text(tr("继续导出副本"))}},dismissButton={TextButton(onClick={confirmation=null}){Text(tr("保留原件"))}})}
 return {file->model.launch{
  if(withContext(Dispatchers.IO){AppleFileMetadata.needsConfirmation(file)})confirmation=file else perform(file)
 }}
}
