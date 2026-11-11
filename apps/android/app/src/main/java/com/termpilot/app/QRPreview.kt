@file:Suppress("DEPRECATION")

package com.termpilot.app

import android.content.Context
import android.graphics.Color
import android.graphics.ImageFormat
import android.hardware.Camera
import android.hardware.display.DisplayManager
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.FrameLayout

/** Owns the camera and an aspect-correct surface within the scanner viewport. */
internal class QRPreview(context:Context,
    private val frame:(ByteArray,Int,Int)->Unit,
    private val failure:()->Unit
):FrameLayout(context),SurfaceHolder.Callback,DisplayManager.DisplayListener {
    private val surface=SurfaceView(context)
    private val displays=context.getSystemService(DisplayManager::class.java)
    private var camera:Camera?=null
    private val info=Camera.CameraInfo()
    private var frameWidth=0
    private var frameHeight=0
    private var orientation=-1
    private var closed=false

    init {
        setBackgroundColor(Color.BLACK)
        addView(surface)
        surface.holder.addCallback(this)
    }

    override fun onAttachedToWindow(){
        super.onAttachedToWindow()
        displays.registerDisplayListener(this,null)
    }
    override fun onDetachedFromWindow(){
        displays.unregisterDisplayListener(this)
        releaseCamera()
        super.onDetachedFromWindow()
    }

    override fun surfaceCreated(holder:SurfaceHolder){
        if(closed)return
        try {
            val id=(0 until Camera.getNumberOfCameras()).firstOrNull {
                Camera.getCameraInfo(it,info);info.facing==Camera.CameraInfo.CAMERA_FACING_BACK
            } ?: 0
            Camera.getCameraInfo(id,info)
            val cam=Camera.open(id)
            camera=cam
            val parameters=cam.parameters
            val size=parameters.supportedPreviewSizes.filter{it.width<=1280&&it.height<=960&&it.width*it.height<=700000}
                .maxByOrNull{it.width*it.height}?:parameters.previewSize
            parameters.setPreviewSize(size.width,size.height)
            parameters.previewFormat=ImageFormat.NV21
            if(parameters.supportedFocusModes?.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)==true)
                parameters.focusMode=Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
            cam.parameters=parameters
            val actual=cam.parameters.previewSize
            frameWidth=actual.width;frameHeight=actual.height
            updateOrientation()
            cam.setPreviewDisplay(holder)
            cam.setPreviewCallback{data,_->
                if(!closed&&data!=null&&data.size>=frameWidth*frameHeight)frame(data,frameWidth,frameHeight)
            }
            cam.setErrorCallback{_,_->releaseCamera();failure()}
            cam.startPreview()
        }catch(_:Exception){releaseCamera();failure()}
    }
    override fun surfaceChanged(holder:SurfaceHolder,format:Int,width:Int,height:Int){updateOrientation()}
    override fun surfaceDestroyed(holder:SurfaceHolder){releaseCamera()}
    override fun onDisplayAdded(id:Int){}
    override fun onDisplayRemoved(id:Int){}
    override fun onDisplayChanged(id:Int){if(display?.displayId==id)updateOrientation()}

    private fun updateOrientation(){
        val cam=camera?:return
        val degrees=when(display?.rotation){Surface.ROTATION_90->90;Surface.ROTATION_180->180;Surface.ROTATION_270->270;else->0}
        val rotation=qrDisplayOrientation(info.orientation,degrees,info.facing==Camera.CameraInfo.CAMERA_FACING_FRONT)
        if(rotation!=orientation){
            try {
                cam.setDisplayOrientation(rotation)
                orientation=rotation
                requestLayout()
            }catch(_:Exception){releaseCamera();failure()}
        }
    }
    override fun onMeasure(widthMeasureSpec:Int,heightMeasureSpec:Int){
        super.onMeasure(widthMeasureSpec,heightMeasureSpec)
        val size=qrPreviewSize(frameWidth,frameHeight,orientation.coerceAtLeast(0),measuredWidth,measuredHeight)
        surface.measure(MeasureSpec.makeMeasureSpec(size.width,MeasureSpec.EXACTLY),MeasureSpec.makeMeasureSpec(size.height,MeasureSpec.EXACTLY))
    }
    override fun onLayout(changed:Boolean,left:Int,top:Int,right:Int,bottom:Int){
        val x=(width-surface.measuredWidth)/2;val y=(height-surface.measuredHeight)/2
        surface.layout(x,y,x+surface.measuredWidth,y+surface.measuredHeight)
    }
    fun close(){closed=true;releaseCamera()}
    private fun releaseCamera(){
        val cam=camera?:return
        camera=null;orientation=-1
        runCatching{cam.setPreviewCallback(null)}
        runCatching{cam.setErrorCallback(null)}
        runCatching{cam.stopPreview()}
        runCatching{cam.release()}
    }
}
