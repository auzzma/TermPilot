"""Opt-in Android native decoder test with real Apple AVC, kept only in memory.

The Mac receives authenticated SRTP; complete access units go over adb stdin to
the emulator adapter. No screen pixels or compressed captures are saved. This
does not validate the Android device's own UDP route or the production UI.
"""
import argparse
import asyncio
from collections import defaultdict
import json
import os
from pathlib import Path
import runpy
import select
import shlex
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PROBE = runpy.run_path(str(ROOT / 'tests/media-codec/test_apple_codec_offer.py'))
ADB = ROOT / '.tools/mobile/android-sdk/platform-tools/adb'

def packed(nals):
    return b''.join(struct.pack('>I',len(n))+n for n in nals)

async def capture(seconds):
    config = PROBE['configuration']('vnc')
    config['seconds'] = seconds
    child = await asyncio.create_subprocess_exec(
        str(ROOT/'target/release/examples/apple_codec_probe'),
        stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,
        env=dict(os.environ,TERMPILOT_CODEC_PROBE='h264',TERMPILOT_CODEC_TILES='1'))
    child.stdin.write(json.dumps(config).encode()+b'\n');await child.stdin.drain();child.stdin.close()
    groups=defaultdict(dict);configs={};total=0
    try:
        while True:
            try:length=struct.unpack('>I',await asyncio.wait_for(child.stdout.readexactly(4),45))[0]
            except asyncio.IncompleteReadError:break
            assert 2<=length<=65536
            h=json.loads(await child.stdout.readexactly(length));n=h['payloadLength'];assert n<=65536
            payload=await child.stdout.readexactly(n)
            if h['kind']!='rtp':continue
            total+=n;assert total<64*1024*1024
            parsed=PROBE['parse_config'](payload) if payload[:1]==b'\x92' else None
            if parsed:configs[h['ssrc']]=parsed[1]
            else:groups[h['ssrc'],h['timestamp']][h['sequence']]=payload
        assert await child.wait()==0,(await child.stderr.read()).decode(errors='replace')[:500]
    finally:
        if child.returncode is None:child.kill();await child.wait()
    by_source=defaultdict(list);waiting=defaultdict(lambda:True)
    for (source,_),group in groups.items():
        nals=PROBE['assemble'](group)
        if not nals:waiting[source]=True;continue
        slices=[n for n in nals if 1<=n[0]&31<=5]
        if any(n[0]&31==5 for n in slices):waiting[source]=False
        if slices and not waiting[source]:by_source[source].append(packed(slices))
    source=max(by_source,key=lambda k:len(by_source[k]))
    assert source in configs and len(by_source[source])>20
    return packed(configs[source]),by_source[source],total

def run_native(remote_dir,config,samples,frame_rate):
    command=f'cd {shlex.quote(remote_dir)} && LD_LIBRARY_PATH=. ./avc_stream_probe'
    child=subprocess.Popen([str(ADB),'-s','emulator-5554','shell','-T','sh','-c',
        shlex.quote(command)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
    def request(op,data=b'',tag=0):
        child.stdin.write(struct.pack('<4I',op,0,tag,len(data))+data);child.stdin.flush()
        assert select.select([child.stdout],[],[],10)[0], 'Android decoder probe timed out'
        line=child.stdout.readline();assert line,line
        r=json.loads(line);assert r['status']>=0 and not r['invalid'],r
        return r
    times=[];first=None;began=time.monotonic();last=None
    try:
        request(1,config)
        began=time.monotonic()
        for tag,data in enumerate(samples):
            if frame_rate:
                deadline=began+tag/frame_rate
                while time.monotonic()<deadline:
                    last=request(3)
                    if last['frames'] and first is None:first=time.monotonic()-began
                    time.sleep(min(.002,max(0,deadline-time.monotonic())))
            last=request(2,data,tag);times.append(last['micros'])
            if last['frames'] and first is None:first=time.monotonic()-began
        for _ in range(200):
            last=request(3)
            if last['frames']>=len(samples):break
            time.sleep(.005)
    finally:
        child.stdin.close()
        try:child.wait(timeout=10)
        except subprocess.TimeoutExpired:child.kill();child.wait()
    return dict(submitted=len(samples),frames=last['frames'],invalid=last['invalid'],
                dimensions=[last['width'],last['height']],decoder=last['decoder'],
                firstFrameSeconds=first,averageDecodeMicros=sum(times)/len(times),maxDecodeMicros=max(times),
                elapsedSeconds=time.monotonic()-began,frameRate=frame_rate)

async def main():
    parser=argparse.ArgumentParser();parser.add_argument('--seconds',type=int,default=6)
    parser.add_argument('--remote-dir',default='/data/local/tmp/termpilot-avc18')
    parser.add_argument('--compare-dir')
    parser.add_argument('--frame-rate',type=int,default=60)
    parser.add_argument('--output',required=True);args=parser.parse_args()
    config,samples,received=await capture(args.seconds)
    print(f'Captured {len(samples)} access units in memory',flush=True)
    report=run_native(args.remote_dir,config,samples,args.frame_rate)
    if args.compare_dir:report['comparison']=run_native(args.compare_dir,config,samples,args.frame_rate)
    report.update(authenticatedPayloadBytes=received,
                  passed=report['frames']==report['submitted'] and report['frames']>20 and not report['invalid'])
    (ROOT/args.output).write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
    assert report['passed'],report
if __name__=='__main__':asyncio.run(main())
