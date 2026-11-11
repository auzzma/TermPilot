package com.termpilot.app

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable

internal data class RemoteCursorPosition(val x:Float,val y:Float)

/** A local, fixed-size pointer over the video surface, with its tip at the click hotspot. */
internal class RemoteCursorDrawable(private val density:Float):Drawable() {
    var tip=RemoteCursorPosition(0f,0f)
        private set
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG)
    private val arrow=Path().apply {
        moveTo(2f,2f);lineTo(2f,25f);lineTo(8f,19f);lineTo(13f,30f)
        lineTo(17f,28f);lineTo(12f,18f);lineTo(22f,18f);close()
    }
    fun place(x:Float,y:Float,visible:Boolean) {
        tip=RemoteCursorPosition(x,y)
        setVisible(visible,false)
        invalidateSelf()
    }
    override fun draw(canvas:Canvas) {
        if(!isVisible)return
        val saved=canvas.save()
        canvas.clipRect(bounds)
        canvas.translate(tip.x-2*density,tip.y-2*density)
        canvas.scale(density,density)
        paint.style=Paint.Style.FILL;paint.color=Color.WHITE;canvas.drawPath(arrow,paint)
        paint.style=Paint.Style.STROKE;paint.color=Color.BLACK
        paint.strokeWidth=1.5f;paint.strokeJoin=Paint.Join.ROUND;canvas.drawPath(arrow,paint)
        canvas.restoreToCount(saved)
    }
    override fun setAlpha(alpha:Int){paint.alpha=alpha;invalidateSelf()}
    override fun setColorFilter(filter:ColorFilter?){paint.colorFilter=filter;invalidateSelf()}
    @Deprecated("Deprecated in Android") override fun getOpacity()=PixelFormat.TRANSLUCENT
}
