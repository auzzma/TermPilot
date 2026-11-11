package com.termpilot.app
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.*
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
@RunWith(AndroidJUnit4::class)
class BackgroundTransferTests {
 @Test fun userInitiatedTransferTaskStartsUpdatesAndFinishes(){
  ActivityScenario.launch(MainActivity::class.java).use{scenario->
   val result=CompletableFuture<Boolean>()
   scenario.onActivity{activity->CoroutineScope(Dispatchers.Main).launch{
    try{val task=TransferBackground.begin(activity,"模拟器传输测试"){};task.progress(1024,2048);TransferBackground.end(activity,task);result.complete(TransferBackground.get(task.id)==null)}catch(e:Throwable){result.completeExceptionally(e)}
   }}
   assertTrue(result.get(25,TimeUnit.SECONDS))
  }
 }
}
