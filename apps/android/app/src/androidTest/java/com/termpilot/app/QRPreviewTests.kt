@file:Suppress("DEPRECATION")

package com.termpilot.app

import android.Manifest
import android.hardware.Camera
import android.view.Surface
import android.widget.FrameLayout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs

class QRPreviewTests {
    @Test fun liveCameraKeepsAspectWhenResizedAndCanReopen(){
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName,Manifest.permission.CAMERA)
        ActivityScenario.launch(MainActivity::class.java).use{scenario->
            repeat(2){
                val frame=AtomicReference<Pair<Int,Int>>()
                val started=CountDownLatch(1)
                val errors=AtomicInteger(0)
                lateinit var preview:QRPreview
                scenario.onActivity{activity->
                    preview=QRPreview(activity,{_,w,h->frame.set(w to h);started.countDown()},{errors.incrementAndGet()})
                    val container=FrameLayout(activity)
                    container.addView(preview,FrameLayout.LayoutParams(900,640))
                    activity.setContentView(container)
                }
                assertTrue("Camera must produce real frames",started.await(15,TimeUnit.SECONDS))
                for((w,h) in listOf(900 to 640,400 to 900,900 to 400)){
                    scenario.onActivity{preview.layoutParams=FrameLayout.LayoutParams(w,h)}
                    instrumentation.waitForIdleSync();Thread.sleep(200)
                    scenario.onActivity{activity->
                        val info=Camera.CameraInfo()
                        val cameraID=(0 until Camera.getNumberOfCameras()).firstOrNull{Camera.getCameraInfo(it,info);info.facing==Camera.CameraInfo.CAMERA_FACING_BACK}?:0
                        Camera.getCameraInfo(cameraID,info)
                        val degrees=when(activity.display?.rotation){Surface.ROTATION_90->90;Surface.ROTATION_180->180;Surface.ROTATION_270->270;else->0}
                        val rotation=qrDisplayOrientation(info.orientation,degrees,info.facing==Camera.CameraInfo.CAMERA_FACING_FRONT)
                        val (fw,fh)=frame.get()
                        val ratio=if(rotation%180==0)fw.toDouble()/fh else fh.toDouble()/fw
                        val surface=preview.getChildAt(0)
                        assertTrue(abs(surface.width-surface.height*ratio)<=1.0)
                        assertTrue(surface.width<=preview.width&&surface.height<=preview.height)
                        assertTrue(abs(surface.left*2+surface.width-preview.width)<=1)
                        assertTrue(abs(surface.top*2+surface.height-preview.height)<=1)
                    }
                }
                scenario.onActivity{activity->preview.close();preview.close();activity.setContentView(FrameLayout(activity))}
                assertEquals("Camera resizing/releasing must not report errors",0,errors.get())
            }
        }
    }
}
