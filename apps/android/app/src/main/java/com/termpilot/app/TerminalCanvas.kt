package com.termpilot.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.text.InputType
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.GestureDetector
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.max

/** Native terminal surface; ANSI parsing, scrollback and screen state live in shared Rust. */
class TerminalCanvas(context:Context,val model:AppModel,val session:Session):View(context) {
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply{typeface=Typeface.MONOSPACE;textSize=model.fontSize*resources.displayMetrics.scaledDensity}
    private var cellWidth=paint.measureText("M")
    private var cellHeight=paint.fontSpacing
    private var screen=JSONObject()
    private var composing=""
    private var touchY=0f
    private var moved=false
    private var held=false
    private val gestures=GestureDetector(context,object:GestureDetector.SimpleOnGestureListener(){
        override fun onDown(e:MotionEvent)=true
        override fun onLongPress(e:MotionEvent){held=true;performContextMenu()}
    })
    init {isFocusable=true;isFocusableInTouchMode=true;setBackgroundColor(Color.rgb(20,22,29));contentDescription="SSH 终端，点击输入，滑动浏览历史";setOnLongClickListener{performContextMenu();true}}
    fun update(value:JSONObject){screen=value;val size=model.fontSize*resources.displayMetrics.scaledDensity;if(paint.textSize!=size){paint.textSize=size;cellWidth=paint.measureText("M");cellHeight=paint.fontSpacing;onSizeChanged(width,height,width,height)};invalidate()}
    override fun onCheckIsTextEditor()=true
    override fun onCreateInputConnection(attrs:EditorInfo):InputConnection {
        attrs.inputType=InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        attrs.imeOptions=EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return object:BaseInputConnection(this,true){
            override fun setComposingText(text:CharSequence?,newCursorPosition:Int):Boolean{composing=text?.toString()?:"";return true}
            override fun commitText(text:CharSequence?,newCursorPosition:Int):Boolean{composing="";model.text(session,text?.toString()?:"");return true}
            override fun finishComposingText():Boolean{if(composing.isNotEmpty()){model.text(session,composing);composing=""};return true}
            override fun deleteSurroundingText(beforeLength:Int,afterLength:Int):Boolean{if(composing.isNotEmpty())composing=composing.dropLast(beforeLength.coerceAtMost(composing.length))else model.text(session,"\u007f".repeat(beforeLength.coerceIn(0,100)));return true}
            override fun sendKeyEvent(event:KeyEvent)=handleKey(event)
            override fun performEditorAction(editorAction:Int):Boolean{model.text(session,"\r");return true}
        }
    }
    override fun onSizeChanged(w:Int,h:Int,oldw:Int,oldh:Int){val cols=max(1,(w/cellWidth).toInt());val rows=max(1,(h/cellHeight).toInt());model.launch{
        model.call(obj("method" to "terminal.resize","id" to session.terminal,"columns" to cols,"rows" to rows))
        model.send(session.id,obj("type" to "resize","cols" to cols,"rows" to rows))
        session.snapshot=model.call(obj("method" to "terminal.snapshot","id" to session.terminal))
    }}
    override fun onDraw(canvas:Canvas){super.onDraw(canvas)
        val cells=screen.optJSONArray("cells")?:return
        for(i in 0 until cells.length()){val c=cells.getJSONObject(i);val x=c.optInt("column")*cellWidth;val y=c.optInt("row")*cellHeight;val inverse=c.optBoolean("inverse")
            val fg=color(c.opt("fg"),Color.rgb(219,223,235));val bg=color(c.opt("bg"),Color.rgb(20,22,29))
            paint.color=if(inverse)fg else bg;canvas.drawRect(x,y,x+cellWidth*c.optInt("width",1),y+cellHeight,paint)
            paint.color=if(inverse)bg else fg;paint.isFakeBoldText=c.optBoolean("bold");canvas.drawText(c.optString("text"),x,y-paint.fontMetrics.ascent,paint)
            if(c.optBoolean("underline"))canvas.drawLine(x,y+cellHeight-2,x+cellWidth,y+cellHeight-2,paint)
        }
        if(!screen.optBoolean("hideCursor")){paint.color=Color.argb(90,90,175,255);val x=screen.optInt("cursorColumn")*cellWidth;val y=screen.optInt("cursorRow")*cellHeight;canvas.drawRect(x,y,x+cellWidth,y+cellHeight,paint)}
    }
    override fun onKeyDown(keyCode:Int,event:KeyEvent):Boolean=handleKey(event)||super.onKeyDown(keyCode,event)
    private fun handleKey(e:KeyEvent):Boolean{if(e.action!=KeyEvent.ACTION_DOWN)return true
        val cursor=if(screen.optBoolean("applicationCursor"))"\u001bO" else "\u001b["
        val text=when(e.keyCode){KeyEvent.KEYCODE_ENTER->"\r";KeyEvent.KEYCODE_DEL->"\u007f";KeyEvent.KEYCODE_ESCAPE->"\u001b";KeyEvent.KEYCODE_TAB->"\t";KeyEvent.KEYCODE_DPAD_UP->cursor+"A";KeyEvent.KEYCODE_DPAD_DOWN->cursor+"B";KeyEvent.KEYCODE_DPAD_RIGHT->cursor+"C";KeyEvent.KEYCODE_DPAD_LEFT->cursor+"D";KeyEvent.KEYCODE_MOVE_HOME->"\u001b[H";KeyEvent.KEYCODE_MOVE_END->"\u001b[F";KeyEvent.KEYCODE_PAGE_UP->"\u001b[5~";KeyEvent.KEYCODE_PAGE_DOWN->"\u001b[6~";else->{val code=e.getUnicodeChar(if(e.isCtrlPressed)e.metaState and KeyEvent.META_CTRL_MASK.inv() else e.metaState);if(code==0)return false;if(e.isCtrlPressed)(code and 31).toChar().toString()else String(Character.toChars(code))}}
        model.text(session,if(e.isAltPressed)"\u001b$text" else text);return true
    }
    override fun onTouchEvent(event:MotionEvent):Boolean{gestures.onTouchEvent(event);when(event.actionMasked){MotionEvent.ACTION_DOWN->{touchY=event.y;moved=false;held=false;return true};MotionEvent.ACTION_MOVE->{val lines=((event.y-touchY)/cellHeight).toInt();if(lines!=0&&!held){moved=true;touchY=event.y;model.launch{model.call(obj("method" to "terminal.scroll","id" to session.terminal,"lines" to lines));session.snapshot=model.call(obj("method" to "terminal.snapshot","id" to session.terminal))}}};MotionEvent.ACTION_UP->{if(!moved&&!held){performClick();requestFocus();(context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(this,InputMethodManager.SHOW_IMPLICIT)}}};return true}
    override fun performClick():Boolean{super.performClick();return true}
    private fun performContextMenu(){val menu=android.widget.PopupMenu(context,this);menu.menu.add("选择和搜索");menu.menu.add("复制当前屏幕");menu.menu.add("粘贴");menu.setOnMenuItemClickListener{item->
        val clipboard=context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        if(item.title=="选择和搜索"){session.searchTerminal=true}
        else if(item.title=="粘贴")clipboard.primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()?.let{model.text(session,if(screen.optBoolean("bracketedPaste"))"\u001b[200~$it\u001b[201~"else it)}
        else model.launch{val text=model.call(obj("method" to "terminal.text","id" to session.terminal)).optString("text");clipboard.setPrimaryClip(android.content.ClipData.newPlainText("TermPilot",text))};true};menu.show()}
    private fun color(value:Any?,fallback:Int):Int{if(value is JSONArray&&value.length()==3)return Color.rgb(value.optInt(0),value.optInt(1),value.optInt(2));if(value !is Number)return fallback;val n=value.toInt();val base=intArrayOf(0xff1d2029.toInt(),0xffed6a5e.toInt(),0xff75c780.toInt(),0xffe7c66a.toInt(),0xff65a8ed.toInt(),0xffbb86d7.toInt(),0xff6dcdd5.toInt(),0xffdce0ea.toInt(),0xff626b80.toInt(),0xffff867a.toInt(),0xff97e7a0.toInt(),0xffffe58e.toInt(),0xff89bdff.toInt(),0xffdda2f5.toInt(),0xff8eeaf2.toInt(),Color.WHITE);if(n<16)return base[n.coerceAtLeast(0)];if(n>=232){val x=8+(n-232)*10;return Color.rgb(x,x,x)};val k=n-16
        fun c(v:Int):Int { return if(v==0)0 else 55+v*40 }
        return Color.rgb(c(k/36),c(k/6%6),c(k%6))}
}
