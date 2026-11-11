package com.termpilot.app

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable fun SyncProfileEditor(model: AppModel, metadata: JSONObject, profile: JSONObject, close: () -> Unit, saved: suspend () -> Unit) {
    val coroutine = rememberCoroutineScope()
    val editing = profile.has("id")
    var title by remember { mutableStateOf(profile.optString("title")) }
    var kind by remember { mutableStateOf(profile.optJSONObject("provider")?.optString("kind") ?: "webdav") }
    val fields = remember { mutableStateMapOf<String, String>().apply { profile.optJSONObject("provider")?.let { p -> p.keys().forEach { key -> if (p.opt(key) is String) put(key, p.getString(key)) } } } }
    var library by remember { mutableStateOf(profile.optString("library")) }
    var name by remember { mutableStateOf(profile.optString("name", "Android")) }
    var password by remember { mutableStateOf("") }
    val scopes = remember { mutableStateListOf<String>().apply { val list = profile.optJSONArray("scopes") ?: JSONArray().put("configuration"); for (i in 0 until list.length()) add(list.getString(i)) } }
    var automatic by remember { mutableStateOf(profile.optBoolean("auto")) }
    var confirmed by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    val providers = metadata.objects("providers")
    val selected = providers.find { it.optString("id") == kind }
    fun save() {
        busy = true; error = ""
        val provider = obj("kind" to kind)
        val definitions = selected?.optJSONArray("fields") ?: JSONArray()
        for (i in 0 until definitions.length()) { val key = definitions.getJSONArray(i).getString(0); provider.put(key, fields[key] ?: "") }
        val request = obj("method" to if (editing) "sync.profile.update" else "sync.profile.add", "id" to profile.optString("id"), "title" to title, "provider" to provider, "library" to library, "name" to name, "passphrase" to password, "scopes" to JSONArray(scopes.toList()), "auto" to automatic, "confirmed" to confirmed)
        coroutine.launch { try { model.call(request); password = ""; saved(); close() } catch (e: Exception) { error = e.message ?: "无法保存配置" } finally { busy = false } }
    }
    FormPage(footer={SyncOperationProgress(model,busy)},onDismissRequest = { if (!busy) close() }, title = { Text(if (editing) "编辑云服务" else "添加云服务") },
        confirmButton = { TextButton(enabled = !busy && confirmed && title.isNotBlank() && (editing || password.length >= 12), onClick = ::save) { Text("保存") } }, text = {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(MobileDesign.sectionGap)) {
            GroupedSection("云服务配置") {
                OutlinedTextField(title, { title = it.take(100) }, Modifier.fillMaxWidth().padding(16.dp), label = { Text("配置名称") }, singleLine = true, enabled = !busy)
                var menu by remember { mutableStateOf(false) }
                Box {
                    SettingRow("服务类型", value = selected?.optString("name") ?: kind, onClick = { if (!busy) menu = true })
                    DropdownMenu(menu, { menu = false }) { providers.forEach { p -> DropdownMenuItem(text = { Text(p.optString("name")) }, onClick = { kind = p.optString("id"); fields.clear(); menu = false }) } }
                }
                selected?.optString("help")?.takeIf { it.isNotBlank() }?.let { Text(it, Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall) }
                val definitions = selected?.optJSONArray("fields") ?: JSONArray()
                for (i in 0 until definitions.length()) {
                    val field = definitions.getJSONArray(i); val key = field.getString(0)
                    if (key == "auth_type") {
                        var authMenu by remember { mutableStateOf(false) }
                        Box {
                            SettingRow("认证方式", value = when (fields[key]) { "digest" -> "Digest"; "token" -> "Bearer Token"; else -> "Basic" }, onClick = { if (!busy) authMenu = true })
                            DropdownMenu(authMenu, { authMenu = false }) { listOf("" to "Basic", "digest" to "Digest", "token" to "Bearer Token").forEach { (value, label) -> DropdownMenuItem(text = { Text(label) }, onClick = { fields[key] = value; authMenu = false }) } }
                        }
                    } else OutlinedTextField(fields[key] ?: "", { fields[key] = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), label = { Text(field.getString(1)) }, singleLine = true, enabled = !busy, visualTransformation = if (field.getBoolean(2)) PasswordVisualTransformation() else VisualTransformation.None)
                }
                if (editing) Text("同一地址和账号下，凭证留空保留原值。更换地址或账号时请重新填写凭证；原云端数据保留。", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(library, { library = it }, Modifier.fillMaxWidth().padding(16.dp), label = { Text("同步库 ID（新建库时留空）") }, singleLine = true, enabled = !editing && !busy)
                if (editing) Text("库 ID 标识现有同步历史。连接其它同步库时，请新增一份配置。", Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().padding(16.dp), label = { Text("当前设备名称") }, singleLine = true, enabled = !busy)
                OutlinedTextField(password, { password = it }, Modifier.fillMaxWidth().padding(16.dp), label = { Text(if (editing) "重新启用同步范围时填写当前 Key" else "同步 Key（至少 12 个字符）") }, singleLine = true, enabled = !busy, visualTransformation = PasswordVisualTransformation())
                Text("同步 Key 用于数据加密，与云服务访问密钥不同。", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
            }
            GroupedSection("此配置的同步范围") {
                val rows = metadata.optJSONArray("scopes") ?: JSONArray()
                for (i in 0 until rows.length()) { val row = rows.getJSONArray(i); val key = row.getString(0)
                    Row(Modifier.padding(16.dp)) { Text(row.getString(1), Modifier.weight(1f)); Switch(scopes.contains(key), { if (it) scopes.add(key) else scopes.remove(key) }, enabled = key != "configuration" && !busy) }
                }
                Row(Modifier.padding(16.dp)) { Text("使用此配置时自动同步", Modifier.weight(1f)); Switch(automatic, { automatic = it }, enabled = !busy) }
                Text("脚本和笔记中的手写秘密不会被自动过滤。其它配置的自动同步在未选用时暂停。", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
                Row(Modifier.padding(16.dp)) { Text("确认保存配置及所选数据合并范围", Modifier.weight(1f)); Checkbox(confirmed, { confirmed = it }, enabled = !busy) }
            }
            if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
            TextButton(enabled = !busy, onClick = close) { Text("取消") }
        }
    })
}
