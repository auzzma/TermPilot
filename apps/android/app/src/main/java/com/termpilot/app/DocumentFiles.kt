package com.termpilot.app

import android.app.Application
import android.net.Uri
import android.provider.DocumentsContract as Docs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** SAF providers supply streams, never a content:// path to the native engine. */
suspend fun AppModel.importFolder(tree:Uri):File=withContext(Dispatchers.IO){
    val resolver=getApplication<Application>().contentResolver
    val staging=File(runtime!!.directory,"Transfers/${UUID.randomUUID()}").apply{mkdirs()}
    var count=0
    suspend fun copy(id:String,parent:File,depth:Int):File {
        ensureActive();check(depth<=32&&++count<=10000){"文件夹超出暂存深度或文件数量限制"}
        val doc=Docs.buildDocumentUriUsingTree(tree,id)
        val meta=resolver.query(doc,arrayOf(Docs.Document.COLUMN_DISPLAY_NAME,Docs.Document.COLUMN_MIME_TYPE,Docs.Document.COLUMN_SIZE),null,null,null)!!.use{
            check(it.moveToFirst());Triple(it.getString(0),it.getString(1),if(it.isNull(2))0L else it.getLong(2))
        }
        check(meta.first.isNotBlank()&&!meta.first.contains('/')&&meta.first!="."&&meta.first!="..")
        val dest=File(parent,meta.first)
        if(meta.second==Docs.Document.MIME_TYPE_DIR){
            check(dest.mkdir()){"无法创建暂存目录"}
            val children=resolver.query(Docs.buildChildDocumentsUriUsingTree(tree,id),arrayOf(Docs.Document.COLUMN_DOCUMENT_ID),null,null,null)!!.use{c->buildList{while(c.moveToNext())add(c.getString(0))}}
            for(child in children)copy(child,dest,depth+1)
        }else{
            check(staging.usableSpace>meta.third+64*1024*1024){"暂存空间不足"}
            resolver.openInputStream(doc).use{input->checkNotNull(input);dest.outputStream().use{out->
                val buffer=ByteArray(256*1024);while(true){ensureActive();val n=input.read(buffer);if(n<0)break;check(staging.usableSpace>64*1024*1024){"暂存空间不足"};out.write(buffer,0,n)};out.fd.sync()
            }}
        }
        return dest
    }
    try{copy(Docs.getTreeDocumentId(tree),staging,0)}catch(e:Exception){staging.deleteRecursively();throw e}
}
suspend fun AppModel.exportFolder(file:File,tree:Uri)=withContext(Dispatchers.IO){
    val resolver=getApplication<Application>().contentResolver
    var count=0
    suspend fun copy(source:File,parent:Uri,depth:Int){
        ensureActive();check(depth<=32&&++count<=10000){"导出目录过大"}
        check(!java.nio.file.Files.isSymbolicLink(source.toPath())){"不能通过文件提供商导出符号链接"}
        val target=Docs.createDocument(resolver,parent,if(source.isDirectory)Docs.Document.MIME_TYPE_DIR else "application/octet-stream",source.name)?:error("文件提供商无法创建目标")
        try {
            if(source.isDirectory)for(child in source.listFiles()?:error("无法读取下载目录"))copy(child,target,depth+1)
            else resolver.openOutputStream(target,"w").use{out->checkNotNull(out);source.inputStream().use{input->val buffer=ByteArray(256*1024);while(true){ensureActive();val n=input.read(buffer);if(n<0)break;out.write(buffer,0,n)}}}
        }catch(e:Exception){runCatching{Docs.deleteDocument(resolver,target)};throw e}
    }
    copy(file,Docs.buildDocumentUriUsingTree(tree,Docs.getTreeDocumentId(tree)),0)
}
