"""Windows system H.264 decoder conformance using synthetic pixels only."""
import pathlib,subprocess,struct,sys,json
root=pathlib.Path(__file__).resolve().parent
def parts(data):
 while data:
  n=struct.unpack('>I',data[:4])[0];assert 0<n<=len(data)-4
  yield data[4:4+n];data=data[4+n:]
p=subprocess.Popen([sys.argv[1]],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
def request(op,data,tag=0):
 p.stdin.write(struct.pack('<4I',op,0,tag,len(data))+data);p.stdin.flush()
 status,count=struct.unpack('<iI',p.stdout.read(8));assert status>=0,(op,tag,status);assert count<=16
 pictures=[]
 for _ in range(count):
  kind,tile,tag,w,h,n=struct.unpack('<6I',p.stdout.read(24));data=p.stdout.read(n)
  assert (kind,tile,w,h,n)==(3,0,96,64,9216) and len(data)==n
  pictures.append(data)
 return pictures
packets=list(parts((root/'h264.fixture').read_bytes()));pictures=[]
try:
 assert not request(1,packets[0])
 for tag,data in enumerate(packets[1:]):pictures+=request(2,data,tag)
 assert len(pictures)==30,len(pictures)
 assert pictures[0]!=pictures[-1], 'Frozen output'
 print(json.dumps(dict(passed=True,codec='H.264',inputFrames=30,decodedFrames=len(pictures),width=96,height=64,pixelFormat='NV12')))
finally:
 p.stdin.close();p.wait(timeout=10)
