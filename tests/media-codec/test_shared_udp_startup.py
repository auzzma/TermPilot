import asyncio,json,struct,sys,tempfile,pathlib,shutil,os
engine=str(pathlib.Path(sys.argv[1]).resolve())
environment={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8'}
if os.name=='nt':
 environment={key:os.environ[key] for key in ('SystemRoot','WINDIR','TEMP','TMP') if key in os.environ}
transport='namedPipe' if os.name=='nt' else 'unixStream'
async def worker(host,lock):
 p=await asyncio.create_subprocess_exec(engine,'screen-sharing',stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL,env=environment)
 p.stdin.write(json.dumps(dict(kind='connect',mode='highPerformance',host=host,port=5900,username='fixture',password='fixture',lockDirectory=lock)).encode()+b'\n');await p.stdin.drain()
 events=[]
 try:
  async with asyncio.timeout(12):
   while True:
    n=struct.unpack('>I',await p.stdout.readexactly(4))[0];header=json.loads(await p.stdout.readexactly(n));await p.stdout.readexactly(header.get('payloadLength',0));events.append(header)
    if header['kind'] in ['mediaTransport','error']:break
 finally:
  if p.returncode is None:
   p.stdin.write(b'{"kind":"disconnect"}\n');await p.stdin.drain();p.stdin.close()
   await p.wait()
 return events[-1]
async def main():
 for i in range(12):
  lock=tempfile.mkdtemp(prefix='termpilot-broker-cold-')
  try:
   result=await asyncio.gather(worker('127.0.0.2',lock),worker('127.0.0.3',lock))
   print(json.dumps({'iteration':i+1,'events':result}),flush=True)
   assert all(e['kind']=='mediaTransport' for e in result)
   assert all(e['transport']==transport for e in result)
   assert result[0]['brokerPID']==result[1]['brokerPID']
  finally:
   await asyncio.sleep(6)
   shutil.rmtree(lock)
asyncio.run(main())
