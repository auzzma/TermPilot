package com.termpilot.app
import android.view.KeyEvent

fun remoteKeysym(event:KeyEvent):Int? {
    return when(event.keyCode){
        KeyEvent.KEYCODE_CTRL_LEFT->0xffe3;KeyEvent.KEYCODE_CTRL_RIGHT->0xffe4
        KeyEvent.KEYCODE_ALT_LEFT->0xffe9;KeyEvent.KEYCODE_ALT_RIGHT->0xffea
        KeyEvent.KEYCODE_SHIFT_LEFT->0xffe1;KeyEvent.KEYCODE_SHIFT_RIGHT->0xffe2
        KeyEvent.KEYCODE_META_LEFT->0xffeb;KeyEvent.KEYCODE_META_RIGHT->0xffec
        KeyEvent.KEYCODE_ESCAPE->0xff1b;KeyEvent.KEYCODE_TAB->0xff09;KeyEvent.KEYCODE_ENTER->0xff0d
        KeyEvent.KEYCODE_DEL->0xff08;KeyEvent.KEYCODE_FORWARD_DEL->0xffff
        KeyEvent.KEYCODE_DPAD_LEFT->0xff51;KeyEvent.KEYCODE_DPAD_RIGHT->0xff53
        KeyEvent.KEYCODE_DPAD_UP->0xff52;KeyEvent.KEYCODE_DPAD_DOWN->0xff54
        KeyEvent.KEYCODE_MOVE_HOME->0xff50;KeyEvent.KEYCODE_MOVE_END->0xff57
        KeyEvent.KEYCODE_PAGE_UP->0xff55;KeyEvent.KEYCODE_PAGE_DOWN->0xff56
        in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12->0xffbe+event.keyCode-KeyEvent.KEYCODE_F1
        else->event.getUnicodeChar(0).takeIf{it>=32}?.let{if(it>255)it or 0x01000000 else it}
    }
}
