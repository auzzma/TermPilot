package com.termpilot.app

import kotlin.math.min
import kotlin.math.roundToInt

/** Camera1 rotates the display, but leaves the decoder's Y plane unchanged. */
internal fun qrDisplayOrientation(sensorDegrees:Int, displayDegrees:Int, front:Boolean):Int =
    if(front)(360-(sensorDegrees+displayDegrees)%360)%360
    else (sensorDegrees-displayDegrees+360)%360

internal data class QRPreviewSize(val width:Int,val height:Int)

/** Fit the entire rotated frame without stretching or hiding QR finder markers. */
internal fun qrPreviewSize(frameWidth:Int,frameHeight:Int,rotation:Int,viewWidth:Int,viewHeight:Int):QRPreviewSize {
    if(viewWidth<=0||viewHeight<=0)return QRPreviewSize(0,0)
    if(frameWidth<=0||frameHeight<=0)return QRPreviewSize(viewWidth,viewHeight)
    val rotated=rotation%180!=0
    val width=if(rotated)frameHeight else frameWidth
    val height=if(rotated)frameWidth else frameHeight
    val scale=min(viewWidth.toDouble()/width,viewHeight.toDouble()/height)
    return QRPreviewSize((width*scale).roundToInt().coerceIn(1,viewWidth),(height*scale).roundToInt().coerceIn(1,viewHeight))
}
