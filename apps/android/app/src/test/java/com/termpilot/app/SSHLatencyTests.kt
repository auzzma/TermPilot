package com.termpilot.app

import org.junit.Assert.*
import org.junit.Test

class SSHLatencyTests {
    @Test fun acceptsCurrentAndLegacySamplesAndRejectsInvalidValues() {
        assertEquals(386,parseSSHLatency("386"))
        assertEquals(386,parseSSHLatency("386.4"))
        assertEquals(9,parseSSHLatency("8.8"))
        assertEquals(0,parseSSHLatency("0.0"))
        for(message in listOf(""," ","NaN","Infinity","-1","1e30","unavailable"))assertNull(parseSSHLatency(message))
    }
}
