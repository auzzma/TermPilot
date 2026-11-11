package com.termpilot.app

import org.json.JSONObject
import org.junit.Assume.assumeTrue

/** Live targets are supplied locally; an unset selector never chooses another server. */
object LiveTestFixture {
    fun hostname(source: JSONObject, role: String): String =
        source.optJSONObject("testTargets")?.optString(role).orEmpty()

    fun host(source: JSONObject, role: String): JSONObject {
        val name = hostname(source, role)
        assumeTrue("Set testTargets.$role in the authorized fixture", name.isNotEmpty())
        return source.objects("hosts").first { it.optString("hostname") == name }
    }
}
