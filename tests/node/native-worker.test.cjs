'use strict';
const {test}=process.argv.includes('--fixture')?{test:()=>{}}:require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const net=require('node:net');const {spawn}=require('node:child_process');const {generateKeyPairSync}=require('node:crypto');const {createRequire}=require('node:module');const readline=require('node:readline');
const root=path.resolve(__dirname,'../..');const modules=process.env.TERMPILOT_TEST_NODE_MODULES||path.join(root,'tests/node/node_modules');const {Server,utils}=createRequire(path.join(modules,'fixture.cjs'))('ssh2');
function fixtureSFTP(sftp,base){
 const handles=new Map();let next=1;
 function local(remote){const value=path.resolve(base,'.'+(remote.startsWith('/')?remote:'/'+remote));if(value!==base&&!value.startsWith(base+path.sep))throw Error('path escape');return value;}
 const attrs=stat=>({mode:stat.mode,uid:stat.uid,gid:stat.gid,size:stat.size,atime:Math.floor(stat.atimeMs/1000),mtime:Math.floor(stat.mtimeMs/1000)});
 const on=(event,run)=>sftp.on(event,(id,...args)=>{try{run(id,...args);}catch(error){sftp.status(id,error.code==='ENOENT'?2:4);}});
 function handle(id,value){const buffer=Buffer.alloc(4);buffer.writeUInt32BE(next++);handles.set(buffer.toString('hex'),value);sftp.handle(id,buffer);}
 const get=h=>handles.get(h.toString('hex'));
 on('REALPATH',(id,p)=>sftp.name(id,[{filename:p==='.'?'/':path.posix.resolve('/',p),longname:'',attrs:{}}]));
 for(const kind of ['STAT','LSTAT'])on(kind,(id,p)=>sftp.attrs(id,attrs(fs.statSync(local(p)))));
 on('FSTAT',(id,h)=>sftp.attrs(id,attrs(fs.fstatSync(get(h).fd))));
 on('OPENDIR',(id,p)=>handle(id,{path:local(p),read:false}));
 on('READDIR',(id,h)=>{const entry=get(h);if(entry.read){sftp.status(id,1);return;}entry.read=true;sftp.name(id,fs.readdirSync(entry.path).map(name=>({filename:name,longname:name,attrs:attrs(fs.statSync(path.join(entry.path,name)))})));});
 on('OPEN',(id,p,flags)=>{let mode=flags&8?(flags&32?'wx':flags&16?'w+':'a+'):'r';handle(id,{fd:fs.openSync(local(p),mode),path:p});});
 on('CLOSE',(id,h)=>{const entry=get(h);if(entry?.fd!==undefined)fs.closeSync(entry.fd);handles.delete(h.toString('hex'));sftp.status(id,0);});
 on('READ',(id,h,offset,length)=>{const bytes=Buffer.alloc(length);const count=fs.readSync(get(h).fd,bytes,0,length,offset);if(count)sftp.data(id,bytes.subarray(0,count));else sftp.status(id,1);});
 on('WRITE',(id,h,offset,data)=>{fs.writeSync(get(h).fd,data,0,data.length,offset);if(get(h).path?.includes('stall'))return;if(get(h).path?.includes('slow'))setTimeout(()=>sftp.status(id,0),20);else sftp.status(id,0);});
 on('MKDIR',(id,p)=>{fs.mkdirSync(local(p));sftp.status(id,0);});on('RMDIR',(id,p)=>{fs.rmdirSync(local(p));sftp.status(id,0);});on('REMOVE',(id,p)=>{fs.unlinkSync(local(p));sftp.status(id,0);});on('RENAME',(id,a,b)=>{fs.renameSync(local(a),local(b));sftp.status(id,0);});on('SETSTAT',(id,p,a)=>{if(a.mode!==undefined)fs.chmodSync(local(p),a.mode);sftp.status(id,0);});on('FSETSTAT',(id,h,a)=>{if(a.mode!==undefined)fs.fchmodSync(get(h).fd,a.mode);sftp.status(id,0);});
}
async function listen(server){await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));return server.address().port;}
async function freePort(){const server=net.createServer();const port=await listen(server);await new Promise(r=>server.close(r));return port;}
// Use OpenSSL SEC1 encoding directly: ssh2's OpenSSH key writer intermittently
// emits keys rejected by its own parser before the client under test connects.
function fixtureHostKey(){return generateKeyPairSync('ec',{namedCurve:'prime256v1',privateKeyEncoding:{format:'pem',type:'sec1'},publicKeyEncoding:{format:'pem',type:'spki'}}).privateKey;}
async function fixture(interactive=false,algorithms=undefined,closeFirstSftp=false){const directory=fs.mkdtempSync(path.join(os.tmpdir(),'TermPilot-worker-'));const remote=path.join(directory,'remote');fs.mkdirSync(remote);fs.writeFileSync(path.join(remote,'中文.txt'),'fixture remote\n');const connections=new Set();const observations={authenticationAttempts:0};const server=new Server({algorithms,hostKeys:[fixtureHostKey()]},client=>{
 connections.add(client);client.on('error',()=>{});client.on('close',()=>connections.delete(client));client.on('authentication',ctx=>{observations.authenticationAttempts++;
 if(!interactive){ctx.method==='password'&&ctx.username==='fixture'&&ctx.password==='fixture-password'?ctx.accept():ctx.reject();return;}
 if(ctx.username!=='fixture'||ctx.method!=='keyboard-interactive'){ctx.reject(['keyboard-interactive']);return;}
 ctx.prompt([{prompt:'Password:',echo:false}],answers=>{
  if(answers[0]!=='fixture-password'){ctx.reject();return;}
  ctx.prompt([{prompt:'Verification code:',echo:false}],answers=>{
   if(answers[0]!=='001122'){ctx.reject();return;}
   ctx.prompt([{prompt:'Second code:',echo:false}],answers=>answers[0]==='334455'?ctx.accept():ctx.reject());
  });
 });
 });
 client.on('ready',()=>{const forwarded=new Map();client.on('close',()=>{for(const server of forwarded.values())server.close();});client.on('request',(accept,reject,name,info)=>{if(name==='tcpip-forward'){const server=net.createServer(socket=>{client.forwardOut(info.bindAddr,info.bindPort,socket.remoteAddress,socket.remotePort,(error,stream)=>{if(error){socket.destroy();return;}socket.pipe(stream).pipe(socket);socket.on('close',()=>stream.destroy());stream.on('close',()=>socket.destroy());});});server.on('error',()=>reject?.());server.listen(info.bindPort,info.bindAddr,()=>{forwarded.set(info.bindPort,server);accept();});}else if(name==='cancel-tcpip-forward'){forwarded.get(info.bindPort)?.close();forwarded.delete(info.bindPort);accept();}else reject?.();});client.on('session',accept=>{const session=accept();session.on('pty',accept=>accept());session.on('window-change',accept=>accept?.());session.on('shell',accept=>{const shell=accept();shell.write('fixture shell\r\n');shell.on('data',data=>shell.write(data));});session.on('exec',(accept,reject,info)=>{const stream=accept();stream.write(info.command==='fixture-exec'?'exec-ok\n':'/\n');stream.exit(0);stream.end();if(info.command==='fixture-drop-transport')setTimeout(()=>client.end(),20);});session.on('sftp',accept=>{const stream=accept();if(closeFirstSftp){closeFirstSftp=false;stream.end();return;}fixtureSFTP(stream,remote);});});client.on('tcpip',(accept,reject,info)=>{const socket=net.connect(info.destPort,info.destIP,()=>{const stream=accept();socket.pipe(stream).pipe(socket);stream.on('close',()=>socket.destroy());});socket.on('error',()=>reject());});});
 });const port=await listen(server);return{directory,remote,port,observations,close:async()=>{for(const c of connections)c.end();await new Promise(r=>server.close(r));fs.rmSync(directory,{recursive:true,force:true});}};}
const engine=process.env.TERMPILOT_TEST_ENGINE||path.join(root,'target/debug/termpilot-engine');
function worker(fix,acceptKeys=true){const child=spawn(engine,['ssh'],{stdio:['pipe','pipe','pipe']});const frames=[];const waits=[];let errorOutput='';child.stderr.on('data',chunk=>errorOutput+=chunk);const send=frame=>child.stdin.write(JSON.stringify(frame)+'\n');
 readline.createInterface({input:child.stdout}).on('line',line=>{const frame=JSON.parse(line);if(frame.type==='credentialPrompt')send({type:'credentialResponse',promptID:frame.promptID,value:frame.message.includes('Second')?'334455':'001122'});if(frame.type==='hostKeyPrompt')send({type:'hostKeyResponse',promptID:frame.promptID,accepted:acceptKeys});frames.push(frame);for(const waiter of waits.slice()){if(waiter.predicate(frame)){waits.splice(waits.indexOf(waiter),1);clearTimeout(waiter.timer);waiter.resolve(frame);}}});
 function wait(predicate,timeout=15000){const found=frames.find(predicate);if(found)return Promise.resolve(found);return new Promise((resolve,reject)=>{const waiter={predicate,resolve,timer:setTimeout(()=>reject(Error('Timed out; frames='+JSON.stringify(frames)+' stderr='+errorOutput)),timeout)};waits.push(waiter);});}
 let next=1;async function request(request,channel='files',timeout=15000){const id=next++;send({type:'sftpRequest',channel,request:{...request,id}});const reply=await wait(f=>f.type==='sftpResponse'&&f.message.id===id&&'ok' in f.message,timeout);if(!reply.message.ok)throw Error(reply.message.error);return reply.message.result;}
 send({type:'connect',modules,config:{hostname:'127.0.0.1',port:fix.port,username:'fixture',authentication:'password',password:'fixture-password',knownHostsFile:path.join(fix.directory,'known_hosts')},cols:80,rows:24});
 return{send,wait,request,child,close:async()=>{child.stdin.end();await new Promise(r=>child.exitCode!==null?r():child.once('exit',r));for(const w of waits)clearTimeout(w.timer);}};}
test('native worker: host key, terminal, shared SFTP, Unicode hashes, exec, local/remote/SOCKS forwarding and disconnect',{timeout:45000},async()=>{
 const fix=await fixture();const w=worker(fix);const echo=net.createServer(s=>s.pipe(s));let echoPort;
 try{await w.wait(f=>f.type==='log'&&f.status==='connected');assert.match(fs.readFileSync(path.join(fix.directory,'known_hosts'),'utf8'),/ecdsa-sha2-nistp256/);w.send({type:'data',data:Buffer.from('中文 input\r').toString('base64')});await w.wait(f=>f.type==='data'&&Buffer.from(f.data,'base64').toString().includes('中文 input'));w.send({type:'resize',cols:100,rows:30});
  w.send({type:'sftpOpen',config:{fileProtocol:'sftp'}});await w.wait(f=>f.type==='sftpReady');const result=await w.request({action:'list',path:'/'});assert.equal(result.entries[0].name,'中文.txt');
  const input=path.join(fix.directory,'input');const output=path.join(fix.directory,'output');const bytes=require('node:crypto').randomBytes(1024*512);fs.writeFileSync(input,bytes);await w.request({action:'upload',localPath:input,remotePath:'/上传.bin',overwrite:false});await w.request({action:'download',remotePath:'/上传.bin',localPath:output,overwrite:false});assert.deepEqual(fs.readFileSync(output),bytes);await assert.rejects(w.request({action:'upload',localPath:input,remotePath:'/上传.bin',overwrite:false}));
  await w.request({action:'writeText',path:'/编辑.txt',content:'edited中文',overwrite:false});assert.equal((await w.request({action:'readText',path:'/编辑.txt'})).text,'edited中文');await w.request({action:'rename',oldPath:'/编辑.txt',newPath:'/renamed.txt'});await w.request({action:'delete',path:'/renamed.txt'});
  w.send({type:'execOpen'});await w.wait(f=>f.type==='execReady');assert.equal((await w.request({action:'exec',command:'fixture-exec'},'exec')).stdout,'exec-ok\n');
  echoPort=await listen(echo);
  for(const kind of ['local','remote','dynamic']){const rule={id:kind,kind,bindAddress:'127.0.0.1',localPort:await freePort(),remoteHost:'127.0.0.1',remotePort:echoPort};await w.request({action:'forwardStart',rule},'exec');const socket=net.connect(rule.localPort,'127.0.0.1');await new Promise(r=>socket.once('connect',r));async function exchange(data,length){return new Promise((resolve,reject)=>{let bytes=Buffer.alloc(0);const timer=setTimeout(()=>{socket.destroy();reject(Error('Forward timeout'));},5000);const read=chunk=>{bytes=Buffer.concat([bytes,chunk]);if(bytes.length>=length){socket.removeListener('data',read);clearTimeout(timer);resolve(bytes);}};socket.on('data',read);socket.write(data);});}if(kind==='dynamic'){assert.deepEqual(await exchange(Buffer.from([5,1,0]),2),Buffer.from([5,0]));const req=Buffer.from([5,1,0,1,127,0,0,1,0,0]);req.writeUInt16BE(echoPort,8);assert.equal((await exchange(req,10))[1],0);}assert.equal((await exchange(Buffer.from('echo'),4)).toString(),'echo');socket.destroy();await w.request({action:'forwardStop',rule},'exec');}
 }finally{await w.close();echo.close();await fix.close();}
});
test('SFTP pause/resume/cancel cleans stages and recursive transfers honor contents',{timeout:45000},async()=>{
 const fix=await fixture();const w=worker(fix);try{
  await w.wait(f=>f.type==='log'&&f.status==='connected');w.send({type:'sftpOpen',config:{fileProtocol:'sftp'}});await w.wait(f=>f.type==='sftpReady');
  const input=path.join(fix.directory,'input');fs.writeFileSync(input,Buffer.alloc(8*1024*1024,37));
  const upload=w.request({action:'upload',localPath:input,remotePath:'/slow.bin',overwrite:false,chunkSizeBytes:65536,chunkConcurrency:2,fileConcurrency:1});
  const progress=await w.wait(f=>f.type==='sftpResponse'&&f.message.event==='progress');const id=progress.message.id;
  await w.request({action:'pause',targetID:id});await new Promise(r=>setTimeout(r,120));
  await w.request({action:'resume',targetID:id});await new Promise(r=>setTimeout(r,80));
  const cancelled=assert.rejects(upload,/cancel/i);await w.request({action:'cancel',targetID:id});await cancelled;
  assert.equal(fs.existsSync(path.join(fix.remote,'slow.bin')),false);assert.equal(fs.readdirSync(fix.remote).some(n=>n.endsWith('.part')),false);
  const source=path.join(fix.directory,'tree');fs.mkdirSync(path.join(source,'中文'),{recursive:true});fs.mkdirSync(path.join(source,'empty'));
  for(let i=0;i<9;i++)fs.writeFileSync(path.join(source,'中文',i+'.dat'),Buffer.alloc(70000+i,i));
  await w.request({action:'upload',localPath:source,remotePath:'/tree',overwrite:false,fileConcurrency:3,chunkConcurrency:2,chunkSizeBytes:1024*1024});
  const target=path.join(fix.directory,'download');await w.request({action:'download',localPath:target,remotePath:'/tree',overwrite:false,fileConcurrency:3});
  for(let i=0;i<9;i++)assert.deepEqual(fs.readFileSync(path.join(target,'中文',i+'.dat')),fs.readFileSync(path.join(source,'中文',i+'.dat')));
  assert.ok(fs.statSync(path.join(target,'empty')).isDirectory());
 }finally{await w.close();await fix.close();}
});
test('cancelling an unacknowledged SFTP write releases the task and leaves the session usable',{timeout:15000},async()=>{
 const fix=await fixture();const w=worker(fix);try{
  await w.wait(f=>f.type==='log'&&f.status==='connected');w.send({type:'sftpOpen',config:{fileProtocol:'sftp'}});await w.wait(f=>f.type==='sftpReady');
  const source=path.join(fix.directory,'input');fs.writeFileSync(source,Buffer.alloc(128*1024,19));
  const task=w.request({action:'upload',localPath:source,remotePath:'/stall.bin',overwrite:false});
  await new Promise(r=>setTimeout(r,150));const start=Date.now();
  const rejected=assert.rejects(task,/cancel/i);await w.request({action:'cancel',targetID:1});await rejected;
  assert.ok(Date.now()-start<3000,'Cancellation waited for the protocol timeout');
  assert.equal(fs.readdirSync(fix.remote).some(n=>n.endsWith('.part')),false);
  assert.equal((await w.request({action:'list',path:'/'})).entries[0].name,'中文.txt');
 }finally{await w.close();await fix.close();}
});
test('multi-round keyboard-interactive authentication preserves every prompt',{timeout:20000},async()=>{
 const fix=await fixture(true);const w=worker(fix);try{
  await w.wait(f=>f.type==='log'&&f.status==='connected');
  await w.wait(f=>f.type==='credentialPrompt'&&f.message==='Verification code:');
  await w.wait(f=>f.type==='credentialPrompt'&&f.message==='Second code:');
 }finally{await w.close();await fix.close();}
});
test('NIST ECDH and AES-128-GCM combinations remain negotiable',{timeout:20000},async()=>{
 const cases=[
  {kex:['ecdh-sha2-nistp256'],cipher:['aes128-gcm@openssh.com']},
  {kex:['ecdh-sha2-nistp384'],cipher:['aes192-ctr'],hmac:['hmac-sha2-256']},
  {kex:['ecdh-sha2-nistp521'],cipher:['aes256-ctr'],hmac:['hmac-sha2-512-etm@openssh.com']},
  {kex:['diffie-hellman-group14-sha256'],cipher:['aes128-ctr'],hmac:['hmac-sha2-256']}
 ];
 for(const algorithms of cases){const fix=await fixture(false,algorithms);const w=worker(fix);try{await w.wait(f=>f.type==='log'&&f.status==='connected');}finally{await w.close();await fix.close();}}
});
test('SHA-1 HMAC-only servers are rejected before password authentication',{timeout:20000},async()=>{
 for(const hmac of ['hmac-sha1','hmac-sha1-etm@openssh.com']){
  const fix=await fixture(false,{cipher:['aes128-ctr'],hmac:[hmac]});const w=worker(fix);
  try{const failure=await w.wait(f=>f.type==='error');assert.match(failure.message,/MAC|algorithm/i);assert.equal(fix.observations.authenticationAttempts,0);assert.equal(fs.existsSync(path.join(fix.directory,'known_hosts')),false);}
  finally{await w.close();await fix.close();}
 }
});
test('native broker reconnects immediately after the shared transport closes',{skip:process.platform==='win32',timeout:25000},async()=>{
 const fix=await fixture();const crypto=require('node:crypto');const connectionID=crypto.randomUUID();
 const socketPath=path.join('/tmp',`TermPilot-${process.getuid()}`,crypto.createHash('sha256').update(connectionID).digest('hex').slice(0,32)+'.sock');
 const broker=spawn(engine,['ssh-broker'],{stdio:['pipe','ignore','ignore']});const clients=[];
 broker.stdin.end(JSON.stringify({hostname:'127.0.0.1',port:fix.port,username:'fixture',password:'fixture-password',authentication:'password',autoAcceptHostKeys:true,knownHostsFile:path.join(fix.directory,'known_hosts'),connectionID})+'\n');
 async function client(){
  const child=spawn(engine,['ssh-files'],{stdio:['pipe','pipe','ignore']});clients.push(child);
  const lines=readline.createInterface({input:child.stdout})[Symbol.asyncIterator]();
  child.stdin.write(JSON.stringify({connectionID,execOnly:true})+'\n');
  const read=async()=>{const line=await lines.next();assert.equal(line.done,false,'Broker closed before result');return JSON.parse(line.value);};
  const ready=await read();assert.equal(ready.event,'ready',JSON.stringify(ready));
  return{child,read,send:value=>child.stdin.write(JSON.stringify(value)+'\n')};
 }
 try{
  for(let n=0;!fs.existsSync(socketPath);n++){assert.ok(n<100,'Broker did not start');await new Promise(r=>setTimeout(r,20));}
  const first=await client();first.send({id:1,action:'exec',command:'fixture-drop-transport'});
  await new Promise(r=>first.child.exitCode!==null?r():first.child.once('exit',r));
  const second=await client();second.send({id:2,action:'exec',command:'fixture-exec'});
  const result=await second.read();assert.equal(result.ok,true);assert.equal(result.result.stdout,'exec-ok\n');
 }finally{
  for(const child of clients){child.stdin.destroy();if(child.exitCode===null){child.kill();await new Promise(r=>child.once('exit',r));}}
  if(broker.exitCode===null){broker.kill();await new Promise(r=>broker.once('exit',r));}
  fs.rmSync(socketPath,{force:true});fs.rmSync(socketPath.replace(/\.sock$/,'.lock'),{force:true});await fix.close();
 }
});
test('key generation accepts private stdin configuration',{timeout:10000},async()=>{
 const child=spawn(engine,['keygen'],{env:{...process.env,TERMPILOT_SSH2_NODE_MODULES:modules,TERMPILOT_KEYGEN_CONFIG_B64:''},stdio:['pipe','pipe','pipe']});let output='';child.stdout.on('data',c=>output+=c);child.stdin.end(JSON.stringify({keyType:'ed25519',comment:'TermPilot fixture',passphrase:'fixture-passphrase'})+'\n');await new Promise((resolve,reject)=>child.once('exit',code=>code===0?resolve():reject(Error('Key generation failed'))));const pair=JSON.parse(output);assert.ok(utils.parseKey(pair.privateKey) instanceof Error);assert.ok(!(utils.parseKey(pair.privateKey,'fixture-passphrase') instanceof Error));assert.match(pair.publicKey,/ssh-ed25519/);
});
test('rejecting a new host key never authenticates',{timeout:20000},async()=>{const fix=await fixture();const w=worker(fix,false);try{await w.wait(f=>f.type==='hostKeyPrompt');await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Rejected host key did not close connection')),10000);if(w.child.exitCode!==null){clearTimeout(timer);resolve();}else w.child.once('exit',()=>{clearTimeout(timer);resolve();});});assert.equal(fs.existsSync(path.join(fix.directory,'known_hosts')),false);}finally{await w.close();await fix.close();}});


if(process.argv.includes('--fixture'))void fixture().then(fix=>{process.stdout.write(JSON.stringify({directory:fix.directory,port:fix.port})+'\n');process.stdin.resume();process.stdin.on('end',()=>void fix.close().then(()=>process.exit(0)));});

test('paused and queued transfers survive more than 30 seconds without byte progress',{timeout:65000},async()=>{
 const fix=await fixture();const w=worker(fix);try{
  await w.wait(f=>f.type==='log'&&f.status==='connected');w.send({type:'sftpOpen',config:{fileProtocol:'sftp'}});await w.wait(f=>f.type==='sftpReady');
  const source=path.join(fix.directory,'long-pause');const bytes=Buffer.alloc(8*1024*1024,73);fs.writeFileSync(source,bytes);
  const first=w.request({action:'upload',localPath:source,remotePath:'/slow-first.bin',overwrite:false,chunkSizeBytes:65536,chunkConcurrency:1,fileConcurrency:1},'files',60000);
  const progress=await w.wait(f=>f.type==='sftpResponse'&&f.message.event==='progress'&&f.message.transferred>0);
  await w.request({action:'pause',targetID:progress.message.id});
  const queued=w.request({action:'upload',localPath:source,remotePath:'/queued-second.bin',overwrite:false,chunkSizeBytes:65536,chunkConcurrency:1,fileConcurrency:1},'files',60000);
  await new Promise(resolve=>setTimeout(resolve,32000));
  assert.equal(fs.existsSync(path.join(fix.remote,'slow-first.bin')),false);
  assert.equal(fs.readdirSync(fix.remote).some(n=>n.startsWith('queued-second.bin')),false);
  await w.request({action:'resume',targetID:progress.message.id});await Promise.all([first,queued]);
  assert.deepEqual(fs.readFileSync(path.join(fix.remote,'slow-first.bin')),bytes);
  assert.deepEqual(fs.readFileSync(path.join(fix.remote,'queued-second.bin')),bytes);
  assert.equal(fs.readdirSync(fix.remote).some(n=>n.endsWith('.part')),false);
 }finally{await w.close();await fix.close();}
});

test('a subsystem closed during negotiation reopens once before touching files',{timeout:15000},async()=>{
 const fix=await fixture(false,undefined,true);const w=worker(fix);try{
  await w.wait(f=>f.type==='log'&&f.status==='connected');
  w.send({type:'sftpOpen',config:{fileProtocol:'sftp'}});await w.wait(f=>f.type==='sftpReady');
  const entries=(await w.request({action:'list',path:'/'})).entries;
  assert.equal(entries[0].name,'中文.txt');
  assert.equal(fix.observations.authenticationAttempts,1);
  assert.deepEqual(fs.readdirSync(fix.remote),['中文.txt']);
 }finally{await w.close();await fix.close();}
});
