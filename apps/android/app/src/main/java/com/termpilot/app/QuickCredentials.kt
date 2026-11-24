package com.termpilot.app

import android.content.SharedPreferences
import androidx.compose.runtime.*
import org.json.JSONObject

enum class QuickCredentialProtocol(val label: String) {
    ssh("SSH"), standardVNC("普通 VNC"), highPerformance("Apple 高性能"), rdp("RDP");

    fun supports(kind: String) = kind == "password" || (this == ssh && kind == "identityKey")

    companion object {
        fun resolve(host: JSONObject): QuickCredentialProtocol = when (host.optString("connectionKind", "ssh")) {
            "rdp" -> rdp
            "screenSharing", "screen" -> if (host.optString("mode") == "highPerformance") highPerformance else standardVNC
            else -> ssh
        }
    }
}

enum class QuickCredentialStrategy(val label: String) {
    manual("每次选择"), recent("记住上次成功使用的凭证"), fixed("固定凭证")
}

class QuickCredentialPreferences(private val preferences: SharedPreferences) {
    private fun key(protocol: QuickCredentialProtocol, field: String) = "quickCredential.${protocol.name}.$field"
    fun strategy(protocol: QuickCredentialProtocol): QuickCredentialStrategy =
        QuickCredentialStrategy.entries.find { it.name == preferences.getString(key(protocol, "strategy"), "") }
            ?: QuickCredentialStrategy.manual
    fun fixed(protocol: QuickCredentialProtocol) = preferences.getString(key(protocol, "fixed"), "") ?: ""
    fun selected(protocol: QuickCredentialProtocol): String = when (strategy(protocol)) {
        QuickCredentialStrategy.manual -> ""
        QuickCredentialStrategy.fixed -> fixed(protocol)
        QuickCredentialStrategy.recent -> preferences.getString(key(protocol, "recent"), "") ?: ""
    }
    fun configure(protocol: QuickCredentialProtocol, strategy: QuickCredentialStrategy, id: String) {
        preferences.edit().putString(key(protocol, "strategy"), strategy.name).putString(key(protocol, "fixed"), id).apply()
    }
    fun connected(protocol: QuickCredentialProtocol, id: String) {
        if (strategy(protocol) == QuickCredentialStrategy.recent && id.isNotBlank()) {
            preferences.edit().putString(key(protocol, "recent"), id).apply()
        }
    }
}

@Composable fun QuickCredentialSettings(model: AppModel) {
    GroupedSection("快速连接凭证") {
        QuickCredentialProtocol.entries.forEach { protocol ->
            var strategy by remember(protocol) { mutableStateOf(model.quickCredentials.strategy(protocol)) }
            var fixed by remember(protocol) { mutableStateOf(model.quickCredentials.fixed(protocol)) }
            val available = model.records["credentials"].orEmpty().filter { protocol.supports(it.optString("kind")) }
            Choice(tr(protocol.label), strategy.name, QuickCredentialStrategy.entries.map { it.name to tr(it.label) }) {
                strategy = QuickCredentialStrategy.valueOf(it)
                model.quickCredentials.configure(protocol, strategy, fixed)
            }
            if (strategy == QuickCredentialStrategy.fixed) {
                val missing = if (fixed.isNotBlank() && available.none { it.optString("id") == fixed }) listOf(fixed to tr("凭证不可用，请重新选择。")) else emptyList()
                Choice(tr("凭证"), fixed, listOf("" to tr("请选择凭证")) + missing + available.map { it.optString("id") to (it.optString("label") + " · " + it.optString("username")) }) {
                    fixed = it
                    model.quickCredentials.configure(protocol, strategy, fixed)
                }
            }
        }
    }
}
