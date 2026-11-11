package com.termpilot.app

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/** A failed control event must not stop video and input feedback for every session. */
internal suspend fun receiveMobileEvents(
    poll:suspend ()->Packet?,
    receive:suspend (Packet)->Unit,
    report:(Exception)->Unit,
) {
    while(currentCoroutineContext().isActive) {
        try {poll()?.let{receive(it)}}
        catch(cancelled:CancellationException){throw cancelled}
        catch(error:Exception){report(error);delay(100)}
    }
}
