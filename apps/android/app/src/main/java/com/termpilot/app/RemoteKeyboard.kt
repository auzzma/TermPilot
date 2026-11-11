package com.termpilot.app

fun AppModel.key(session:Session,code:Int,modifier:Int?=null)=launch {
    sendSequence(session.id,remoteKeyPress(code,modifier))
}
