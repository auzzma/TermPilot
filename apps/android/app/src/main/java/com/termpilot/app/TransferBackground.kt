package com.termpilot.app

import android.app.*
import android.app.job.*
import android.content.*
import android.net.NetworkRequest
import android.os.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout

/** One finite OS task per user-started SFTP transfer. Never restarts a shell or upload. */
object TransferBackground {
    private const val channel="TermPilot.transfers"
    private var next=100
    class Work(val id:Int,val title:String,val cancel:()->Unit){
        val ready=CompletableDeferred<Unit>()
        var finish:(()->Unit)?=null
        var progress:(Long,Long)->Unit={_,_->}
        private var lastProgress=0L
        fun report(done:Long,total:Long){val now=SystemClock.elapsedRealtime();if(done>=total||now-lastProgress>=500){lastProgress=now;progress(done,total)}}
    }
    private val work=mutableMapOf<Int,Work>()
    fun get(id:Int)=work[id]
    fun notification(context:Context,w:Work,done:Long=0,total:Long=0):Notification {
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(channel,"文件传输",NotificationManager.IMPORTANCE_LOW))
        val open=PendingIntent.getActivity(context,w.id,Intent(context,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop=PendingIntent.getBroadcast(context,w.id,Intent(context,TransferCancel::class.java).putExtra("id",w.id),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(context,channel).setContentTitle("TermPilot · ${w.title}")
            .setSmallIcon(android.R.drawable.stat_sys_upload).setContentIntent(open).setOngoing(true)
            .setContentText("${done/1024} / ${total/1024} KiB")
            .setProgress(100,if(total>0)(done*100/total).toInt().coerceIn(0,100)else 0,total<=0)
            .addAction(Notification.Action.Builder(null,"取消",stop).build()).build()
    }
    suspend fun begin(context:Context,title:String,cancel:()->Unit):Work {
        val w=Work(++next,title,cancel);work[w.id]=w
        try {
            if(Build.VERSION.SDK_INT>=34){
                val info=JobInfo.Builder(w.id,ComponentName(context,TransferJob::class.java))
                    .setUserInitiated(true).setRequiredNetwork(NetworkRequest.Builder().build()).build()
                check(context.getSystemService(JobScheduler::class.java).schedule(info)==JobScheduler.RESULT_SUCCESS){"系统暂时不能运行后台传输，请保持应用前台后重试"}
            }else context.startForegroundService(Intent(context,TransferService::class.java).putExtra("id",w.id))
            withTimeout(15000){w.ready.await()}
            return w
        }catch(e:Exception){end(context,w);throw e}
    }
    fun end(context:Context,w:Work){
        work.remove(w.id)
        w.finish?.invoke()
        if(Build.VERSION.SDK_INT>=34)context.getSystemService(JobScheduler::class.java).cancel(w.id)
        context.getSystemService(NotificationManager::class.java).cancel(w.id)
    }
}
class TransferCancel:BroadcastReceiver(){override fun onReceive(context:Context,intent:Intent){TransferBackground.get(intent.getIntExtra("id",0))?.cancel?.invoke()}}
class TransferJob:JobService(){
    override fun onStartJob(params:JobParameters):Boolean {
        val w=TransferBackground.get(params.jobId)?:return false
        if(Build.VERSION.SDK_INT<34)return false
        setNotification(params,w.id,TransferBackground.notification(this,w),JOB_END_NOTIFICATION_POLICY_REMOVE)
        w.finish={jobFinished(params,false)}
        w.progress={done,total->setNotification(params,w.id,TransferBackground.notification(this,w,done,total),JOB_END_NOTIFICATION_POLICY_REMOVE)}
        w.ready.complete(Unit);return true
    }
    override fun onStopJob(params:JobParameters):Boolean {TransferBackground.get(params.jobId)?.cancel?.invoke();return false}
}
class TransferService:Service(){
    private val active=mutableSetOf<Int>()
    override fun onBind(intent:Intent?):IBinder?=null
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        val w=TransferBackground.get(intent?.getIntExtra("id",0)?:0)?:run{stopSelf(startId);return START_NOT_STICKY}
        active.add(w.id);startForeground(w.id,TransferBackground.notification(this,w))
        w.finish={active.remove(w.id);if(active.isEmpty()){stopForeground(STOP_FOREGROUND_REMOVE);stopSelf()}}
        w.progress={done,total->getSystemService(NotificationManager::class.java).notify(w.id,TransferBackground.notification(this,w,done,total))}
        w.ready.complete(Unit);return START_NOT_STICKY
    }
    override fun onTimeout(startId:Int,fgsType:Int){active.toList().forEach{TransferBackground.get(it)?.cancel?.invoke()};stopSelf()}
}
