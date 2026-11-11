package com.termpilot.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

object NativeBridge {
    init { System.loadLibrary("termpilot_mobile") }
    @JvmStatic external fun create(directory: String, key: ByteArray): Long
    @JvmStatic external fun call(runtime: Long, request: String): String
    @JvmStatic external fun poll(runtime: Long, timeoutMs: Int): ByteArray?
    @JvmStatic external fun destroy(runtime: Long)
}
data class Packet(val header: JSONObject, val payload: ByteArray)
internal fun decodeMobilePacket(bytes: ByteArray): Packet {
    require(bytes.size >= 4) { "Invalid mobile event packet" }
    val length = ByteBuffer.wrap(bytes, 0, 4).int
    // Control events carry JSON command output and file text, which may exceed 64 KiB.
    // Keep a bound large enough for the engine's 16 MiB output plus JSON escaping.
    require(length in 2..(128 * 1024 * 1024) && length <= bytes.size - 4) { "Invalid mobile event length" }
    return Packet(JSONObject(String(bytes, 4, length, Charsets.UTF_8)), bytes.copyOfRange(4 + length, bytes.size))
}
class MobileRuntime(context: Context) {
    val directory = File(context.filesDir, "TermPilot").apply { mkdirs() }
    val handle: Long
    private val calls = Mutex()
    init {
        val key = vaultKey()
        try { handle = NativeBridge.create(directory.absolutePath, key); check(handle != 0L) { "无法打开 TermPilot 数据库，请检查加密密钥与备份。" } }
        finally { key.fill(0) }
    }
    private fun vaultKey(): ByteArray {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "TermPilot.vault"
        val wrapped = File(directory, "vault-key.encrypted")
        if (!store.containsAlias(alias)) {
            check(!wrapped.exists() && !File(directory,"vault.sqlite").exists()) { "设备密钥已丢失，请使用加密备份恢复。" }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
            generator.generateKey()
        }
        val key = store.getKey(alias,null) as SecretKey
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        if (wrapped.exists()) {
            val bytes = wrapped.readBytes(); check(bytes.size >= 60) { "加密密钥文件无效" }
            cipher.init(Cipher.DECRYPT_MODE,key,GCMParameterSpec(128,bytes.copyOfRange(0,12)))
            return cipher.doFinal(bytes.copyOfRange(12,bytes.size)).also { check(it.size == 32) }
        }
        check(!File(directory,"vault.sqlite").exists()) { "加密密钥缺失，不能覆盖现有数据库。" }
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        cipher.init(Cipher.ENCRYPT_MODE,key)
        val staging = File(directory,"vault-key.encrypted.tmp")
        staging.outputStream().use { it.write(cipher.iv); it.write(cipher.doFinal(bytes)); it.fd.sync() }
        check(staging.renameTo(wrapped)) { "无法保存设备密钥" }
        return bytes
    }
    private fun invoke(request:JSONObject):JSONObject {
        val reply = JSONObject(NativeBridge.call(handle, request.toString()))
        check(reply.optBoolean("ok")) { reply.optJSONObject("error")?.optString("message") ?: "引擎调用失败" }
        return reply.optJSONObject("value") ?: JSONObject()
    }
    suspend fun call(request: JSONObject): JSONObject {
        if(request.optString("method").startsWith("sync.")&&request.optString("method")!="sync.preferences")
            return withContext(Dispatchers.IO) { invoke(request) }
        // Queue on the caller's dispatcher before hopping to the thread pool.
        // Otherwise a later key-up/text event can overtake an earlier key-down.
        return calls.withLock { withContext(Dispatchers.IO) { invoke(request) } }
    }
    suspend fun poll(): Packet? = withContext(Dispatchers.IO) {
        val bytes = NativeBridge.poll(handle,100) ?: return@withContext null
        decodeMobilePacket(bytes)
    }
    fun close() = NativeBridge.destroy(handle)
}
fun obj(vararg items: Pair<String,Any?>) = JSONObject().apply { items.forEach { (k,v) -> put(k,v ?: JSONObject.NULL) } }
fun JSONObject.objects(key: String): List<JSONObject> = optJSONArray(key)?.let { a -> (0 until a.length()).mapNotNull { a.optJSONObject(it) } } ?: emptyList()
