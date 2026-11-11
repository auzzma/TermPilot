package com.termpilot.app

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs

class QRPreviewGeometryTests {
    @Test fun keepsFrameAspectAcrossPhoneTabletAndWindowSizes(){
        for((width,height) in listOf(1080 to 960,800 to 320,320 to 800,1600 to 900)){
            for(rotation in listOf(0,90,180,270)){
                val size=qrPreviewSize(640,480,rotation,width,height)
                assertTrue(size.width<=width&&size.height<=height)
                assertTrue(size.width==width||size.height==height)
                val expected=if(rotation%180==0)640.0/480 else 480.0/640
                assertTrue("Frame must retain its aspect ratio",abs(size.width-size.height*expected)<=1.0)
            }
        }
        // The old full-width 1080x960 surface stretched a portrait 480x640 frame.
        assertEquals(QRPreviewSize(720,960),qrPreviewSize(640,480,90,1080,960))
    }
    @Test fun usesSensorAndDisplayRotationIncludingReversePortrait(){
        assertEquals(listOf(90,0,270,180),listOf(0,90,180,270).map{qrDisplayOrientation(90,it,false)})
        assertEquals(listOf(270,180,90,0),listOf(0,90,180,270).map{qrDisplayOrientation(270,it,false)})
        assertEquals(listOf(0,270,180,90),listOf(0,90,180,270).map{qrDisplayOrientation(0,it,false)})
        assertEquals(270,qrDisplayOrientation(90,0,true))
        assertEquals(0,qrDisplayOrientation(90,270,true))
    }
}
