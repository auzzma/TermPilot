package com.termpilot.app

import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MobileDesktopControlsTests {
    private fun controls()=MobileDesktopControls().apply{available={true};keyTimeout=50;resizeTimeout=50}
    @Test fun unicodePasswordIsAcknowledgedAndSubmittedOnce()=runBlocking{withContext(Dispatchers.Main){
        val c=controls();val keys=mutableListOf<Int>();val kinds=mutableListOf<String>()
        c.send={e->kinds.add(e.optString("kind"));assertFalse(e.has("password"));assertFalse(e.has("text"));if(e.optString("kind")=="credentialKey"){keys.add(e.getInt("key"));c.receive(obj("kind" to "credentialKeySent","requestID" to e.getString("requestID")))}}
        c.login{"A!空🔑é"};assertEquals(listOf(65,33,0x01007a7a,0x0101f511,233,0xff0d),keys);assertEquals("release",kinds.first());assertEquals("release",kinds.last());assertFalse(c.loginBusy)
    }}
    @Test fun wrongAcknowledgementDuplicateClickAndCancelCannotSubmit()=runBlocking{withContext(Dispatchers.Main){
        val c=controls();c.keyTimeout=2000;val keys=mutableListOf<JSONObject>();c.send={if(it.optString("kind")=="credentialKey")keys.add(it)}
        val task=launch{c.login{"abc"}};delay(20)
        c.login{fail("duplicate resolves credentials");"wrong"};c.receive(obj("kind" to "credentialKeySent","requestID" to "stale"));assertEquals(1,keys.size)
        c.cancelLogin();task.join();c.receive(obj("kind" to "credentialKeySent","requestID" to keys[0].getString("requestID")));assertEquals(1,keys.size);assertFalse(c.loginBusy)
    }}
    @Test fun timeoutOrTransportFailureNeverSubmitsPartialPassword()=runBlocking{withContext(Dispatchers.Main){
        for(fail in listOf(false,true)){val c=controls();val keys=mutableListOf<Int>();c.send={if(it.optString("kind")=="credentialKey"){keys.add(it.getInt("key"));if(fail)throw IllegalStateException("transport")}};c.login{"secret"};assertEquals(listOf(115),keys);assertFalse(c.loginBusy);assertFalse(c.loginMessage.contains("secret"))}
    }}
    @Test fun cancellationDuringResolutionAndInvalidPasswordsSendNoKeys()=runBlocking{withContext(Dispatchers.Main){
        val c=controls();var sent=0;c.send={if(it.optString("kind")=="credentialKey")sent++}
        val task=launch{c.login{delay(40);"secret"}};delay(10);c.cancelLogin();task.join()
        for(password in listOf("","line\nreturn","x".repeat(1025)))c.login{password}
        assertEquals(0,sent)
    }}
    @Test fun resizeRequiresCapabilityHandlesForwardedRejectionAndLateReply()=runBlocking{withContext(Dispatchers.Main){
        val c=controls();val sent=mutableListOf<JSONObject>();c.send={sent.add(it)};val size=DesktopResolution.presets[0]
        c.resizeVNC(size);assertTrue(sent.isEmpty());c.receive(obj("kind" to "vncCapabilities","canResize" to true));c.resizeVNC(size)
        val id=sent[0].getString("requestID");assertEquals(1280,sent[0].getInt("width"));c.receive(obj("kind" to "vncResizeResult","requestID" to "stale","accepted" to true));assertTrue(c.resizeBusy)
        c.receive(obj("kind" to "vncResizeResult","requestID" to id,"pending" to true));assertTrue(c.resizeBusy);c.resizeVNC(size);assertEquals(1,sent.size)
        delay(80);assertTrue(c.resizeBlocked);assertFalse(c.resizeBusy)
        c.receive(obj("kind" to "vncResizeResult","requestID" to id,"accepted" to false,"code" to "vncResizeProhibited"));assertFalse(c.resizeBlocked);assertTrue(c.resizeMessage.contains("不允许"))
        c.resizeVNC(size);c.receive(obj("kind" to "vncResizeResult","requestID" to sent[1].getString("requestID"),"accepted" to true));assertFalse(c.resizeBusy)
        c.receive(obj("kind" to "vncCapabilities","canResize" to false));c.resizeVNC(size);assertEquals(2,sent.size);c.stop()
    }}
    @Test fun highPerformanceUsesReconnectAndDoesNotOverlapLogin()=runBlocking{withContext(Dispatchers.Main){
        val c=controls();var count=0;c.send={fail("HP must reconnect")}
        c.reconnectResolution{count++;c.reconnectResolution{fail("duplicate")};c.login{fail("login during reconnect");"secret"}}
        assertEquals(1,count);assertFalse(c.resizeBusy)
    }}
    @Test fun leavingPanelCancelsAndDesktopDimensionsValidate()=runBlocking{withContext(Dispatchers.Main){
        val s=Session(990,obj("mode" to "highPerformance"),"screen","");val c=s.desktopControls;c.available={true};c.keyTimeout=2000
        var keys=0;c.send={if(it.optString("kind")=="credentialKey")keys++}
        val task=launch{c.login{"abc"}};delay(20);s.activePanel="ai";task.join();assertEquals(1,keys)
        s.receiveDesktopSize(obj("width" to 2560,"height" to 1440));assertEquals(DesktopResolution(2560,1440),s.desktopRenderSize)
        s.receiveDesktopSize(obj("width" to 0,"height" to -1));assertEquals(DesktopResolution(2560,1440),s.desktopSize)
    }}
}
