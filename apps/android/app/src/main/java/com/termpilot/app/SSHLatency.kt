package com.termpilot.app

import kotlin.math.roundToInt

internal fun parseSSHLatency(message:String):Int? {
    val value=message.trim().toDoubleOrNull()?:return null
    if(!value.isFinite()||value<0||value>Int.MAX_VALUE.toDouble())return null
    return value.roundToInt()
}
