"""Opt-in production broker acceptance. No adapter or external broker process.
Only the named Macs' saved credentials are read, and only private stdin carries
them. No remote inputs, clipboard operations, file transfers or saved media.
"""
import argparse
import asyncio
import fcntl
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import sys
import tempfile
import time
import uuid

from test_shared_udp_live import ROOT, Worker, Viewer, observe, configuration


class ProductionWorker(Worker):
    async def start(self, base, engine, codec, size, viewer=None):
        self.viewer = viewer
        self.sid = uuid.uuid4().hex
        self.host, self.codec, self.size = base["host"], codec, size
        self.frames = self.audio = 0
        self.tiles, self.errors, self.bindings = set(), [], []
        self.diagnostics, self.media_transport = {}, {}
        self.connected = self.stopping = False
        self.started = time.monotonic()
        self.last_frame = self.last_audio = None
        self.child = await asyncio.create_subprocess_exec(str(engine), "screen-sharing",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env={"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"})
        self.reader = asyncio.create_task(self.read())
        self.stderr = asyncio.create_task(self.read_stderr())
        await self.send(dict(base, kind="connect", mode="highPerformance", videoCodec=codec,
            width=size[0], height=size[1], frameRate=30, audio=True,
            lockDirectory=str(Path(tempfile.gettempdir()) / "com.termpilot.screen-sharing")))
        return self

    async def ready(self):
        async with asyncio.timeout(95):
            while True:
                self.check()
                if self.connected and self.tiles == set(range(self.tile_count)) and self.audio:
                    assert self.media_transport.get("transport") == "unixStream"
                    assert self.media_transport.get("brokerPID",0) > 1
                    assert not self.bindings, "Unexpected test adapter"
                    return
                await asyncio.sleep(.2)

    async def close(self, force=False, allow_error=False):
        self.stopping = True
        if self.child.returncode is None:
            if force:
                self.child.kill()
            else:
                try:
                    await self.send(dict(kind="disconnect"))
                    self.child.stdin.close()
                except (BrokenPipeError,ConnectionResetError):pass
            try:await asyncio.wait_for(self.child.wait(),10)
            except asyncio.TimeoutError:
                self.child.kill();await self.child.wait();raise AssertionError("Engine did not close")
        await self.reader;await self.stderr
        if self.viewer:self.viewer.clear(self.host)
        if not force and not allow_error:assert self.child.returncode==0


async def main(args):
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
    engine=args.engine.resolve();base=[configuration("vnc",host=h) for h in args.hosts]
    report=dict(hosts=args.hosts,productionBroker=True,externalAdapter=False,
        engineSHA256=hashlib.sha256(engine.read_bytes()).hexdigest(),phases=[],sessions=[],passed=False)
    active=[];viewer=None;started=time.monotonic()
    def save():
        report["elapsedSeconds"]=round(time.monotonic()-started,3)
        (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    async def launch(index,codec,size=(1920,1080),ready=True):
        w=await ProductionWorker().start(base[index],engine,codec,size,viewer)
        active.append(w)
        if ready:await w.ready()
        return w
    async def close(w,force=False,allow_error=False):
        await w.close(force,allow_error)
        report['sessions'].append(dict(w.report(),exitCode=w.child.returncode,intentionalKill=force,expectedError=allow_error))
        active.remove(w);save()
    def checkpoint(name,workers):
        ids={w.media_transport['brokerPID'] for w in workers}
        assert len(ids)==1
        assert len({w.child.pid for w in workers})==len(workers)
        report['phases'].append(dict(name=name,brokerPID=next(iter(ids)),workers=[w.report() for w in workers]))
        save();print(json.dumps(dict(phase=name,brokerPID=next(iter(ids)),workers=[dict(host=w.host,pid=w.child.pid,codec=w.codec,size=w.size,frames=w.frames,audio=w.audio) for w in workers])),flush=True)
    try:
        if args.viewer:viewer=await Viewer().start(args.viewer.resolve())
        for codec in args.codecs:
            a,b=await asyncio.gather(launch(0,codec),launch(1,codec))
            checkpoint(codec+'-both-connected',[a,b])
            await observe([a,b],args.seconds)
            checkpoint(codec+'-simultaneous',[a,b])
            if codec==args.codecs[0]:
                duplicate=await launch(0,codec,ready=False)
                async with asyncio.timeout(10):
                    while not duplicate.errors:await asyncio.sleep(.1)
                assert 'screenSessionAlreadyActive' in duplicate.errors
                await close(duplicate,allow_error=True)
                checkpoint('duplicate-target-rejected',[a,b])
                for cycle in range(args.reconnects):
                    old_audio=b.audio;old_pid=b.child.pid
                    await close(a)
                    size=[(1280,720),(1920,1080),(2560,1440),(3840,2160)][cycle%4]
                    a=await launch(0,codec,size)
                    await asyncio.sleep(1)
                    a.check();b.check()
                    assert b.child.pid==old_pid and b.audio>old_audio
                    checkpoint(f'reconnect-{cycle+1}',[a,b])
            await close(a,force=True)
            await observe([b],5)
            checkpoint(codec+'-worker-crash-isolated',[b])
            a=await launch(0,codec)
            checkpoint(codec+'-worker-reconnected',[a,b])
            await close(a);await close(b)
        # The broker is shared failure infrastructure. Verify prompt detection,
        # stale-socket recovery and one replacement broker for both new leases.
        a,b=await asyncio.gather(launch(0,'h264'),launch(1,'h264'))
        old_broker=a.media_transport['brokerPID'];assert b.media_transport['brokerPID']==old_broker
        os.kill(old_broker,signal.SIGKILL)
        async with asyncio.timeout(12):
            while not all('mediaBrokerDisconnected' in w.errors for w in [a,b]):await asyncio.sleep(.1)
        await close(a,allow_error=True);await close(b,allow_error=True)
        a,b=await asyncio.gather(launch(0,'h264'),launch(1,'h264'))
        assert a.media_transport['brokerPID']!=old_broker
        checkpoint('broker-restarted-both-reconnected',[a,b])
        await observe([a,b],10)
        await close(a);await close(b)
        if viewer:
            report['viewer']=dict(viewer.presented)
            assert all(viewer.presented.get(h,{}).get('presented',0)>0 for h in args.hosts)
        # Empty ports are released immediately; the idle broker exits after 5 s.
        async with asyncio.timeout(10):
            while True:
                sockets=[]
                try:
                    for port in [5900,5901]:
                        s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sockets.append(s);s.bind(('0.0.0.0',port))
                    path=Path(tempfile.gettempdir())/'com.termpilot.screen-sharing/screen-sharing.lock'
                    with path.open('r+b') as f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    break
                except BlockingIOError:await asyncio.sleep(.2)
                except OSError as error:
                    if error.errno not in (35,48):raise
                    await asyncio.sleep(.2)
                finally:
                    for s in sockets:s.close()
        report['portsAndLockReleased']=True
        report['passed']=True
    except Exception as error:
        report['error']=type(error).__name__+': '+str(error)[:300]
        print(json.dumps(dict(error=report['error'])),flush=True)
    finally:
        for w in list(active):
            try:await close(w,allow_error=True)
            except Exception as error:report.setdefault('cleanupErrors',[]).append(type(error).__name__)
        if viewer:await viewer.close()
        save()
    print(json.dumps(dict(passed=report['passed'],sessions=len(report['sessions']),phases=len(report['phases']),report=str(out/'results.json'))),flush=True)
    return 0 if report['passed'] else 1


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('--hosts',nargs=2,required=True)
    p.add_argument('--engine',type=Path,default=ROOT/'target/release/termpilot-engine')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--viewer',type=Path)
    p.add_argument('--seconds',type=int,default=60)
    p.add_argument('--reconnects',type=int,default=30)
    p.add_argument('--codecs',nargs='+',default=['h264','h265'],choices=['h264','h265'])
    sys.exit(asyncio.run(main(p.parse_args())))
