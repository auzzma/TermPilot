#!/usr/bin/env python3
"""Native codec smoke tests. No application credentials or recorded screen data."""
import json,math,struct,subprocess,sys
from pathlib import Path
helper=Path(sys.argv[1]).resolve()
# A synthetic 64x64 HEVC 4:4:4 IDR generated with libx265.
nals=[bytes.fromhex(s) for s in [
 '40010c01ffff0408000003009e280000030000baba0240',
 '4201010408000003009e280000030000ba90041020b2dd25261734040000030004003d090020',
 '4401c07030601120','2801ade0d117ffd39173238b80']]
def packet(kind,data,tile=0,tag=0):return struct.pack('<IIII',kind,tile,tag,len(data))+data
source=Path(__file__).with_name('eld-sbr.fixture').read_bytes();asc=source[1:1+source[0]];source=source[1+source[0]:];audio=[]
while source:
 n=struct.unpack('>H',source[:2])[0];audio.append(source[2:2+n]);source=source[2+n:]
requests=[packet(3,bytes.fromhex('f8e65132e000')),packet(1,b''.join(struct.pack('>I',len(n))+n for n in nals[:3])),*[packet(2,nals[3],i,i+123) for i in range(4)],packet(3,asc),*[packet(4,a)for a in audio]]
r=subprocess.run([str(helper)],input=b''.join(requests),capture_output=True,timeout=30,check=True)
b=r.stdout;video=[];pcm=[]
for _ in requests:
 status,count=struct.unpack('<iI',b[:8]);b=b[8:];assert status==0,(status,r.stderr.decode(errors='replace'));assert count<=16
 for _ in range(count):
  kind,tile,tag,w,h,n=struct.unpack('<6I',b[:24]);b=b[24:];data=b[:n];b=b[n:];assert len(data)==n
  if kind==1:assert(w,h,n)==(64,64,12288);video.append((tile,tag))
  elif kind==2:assert(w,h,n)==(480,48000,3840);pcm.extend(struct.unpack('<960f',data))
assert video==[(i,i+123)for i in range(4)],video
assert len(pcm)==len(audio)*960 and all(math.isfinite(x)and abs(x)<=1 for x in pcm)
assert max(map(abs,pcm))>.05
assert not b
# Length is rejected before allocation; a corrupt producer cannot request >16 MiB.
r=subprocess.run([str(helper)],input=struct.pack('<IIII',2,0,0,0xffffffff),capture_output=True,timeout=5)
assert r.returncode!=0
print(json.dumps({'videoTiles':len(video),'audioFrames':len(pcm)//2,'audioRate':48000,'malformedInputRejected':True}))
from test_recovery import validate
print(json.dumps({'lossRecovery': validate(helper)}))
