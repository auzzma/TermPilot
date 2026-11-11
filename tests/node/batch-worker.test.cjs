'use strict';
const {test}=process.argv.includes('--fixture')?{test:()=>{}}:require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const {spawn}=require('node:child_process');const {generateKeyPairSync}=require('node:crypto');const {Server}=require('ssh2');const readline=require('node:readline');
const engine=process.env.TERMPILOT_TEST_ENGINE||process.env.TERMPILOT_ENGINE||path.resolve(__dirname,'../../target/release/termpilot-engine');
const login='batch-fixture-login-password',rootPassword='batch-fixture-root-password';
async function fixture(options={}){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'TermPilot-batch-'));const observations=[];const clients=new Set();
 const map=p=>p.replace(/\/tmp\/(?:ssh|termpilot)-batch-([a-f0-9-]+)/g,`${directory}/work-$1`);
 function local(p){const v=path.resolve(map(p));if(!v.startsWith(directory+path.sep))throw Error('fixture path escape');return v;}
 function sftp(stream){const handles=new Map();let next=1;const attrs=s=>({mode:s.mode,uid:s.uid,gid:s.gid,size:s.size,atime:Math.floor(s.atimeMs/1000),mtime:Math.floor(s.mtimeMs/1000)});const on=(e,f)=>stream.on(e,(id,...args)=>{try{f(id,...args);}catch(error){stream.status(id,error.code==='ENOENT'?2:4);}});const get=h=>handles.get(h.toString('hex'));function handle(id,v){const h=Buffer.alloc(4);h.writeUInt32BE(next++);handles.set(h.toString('hex'),v);stream.handle(id,h);}
  on('REALPATH',(id,p)=>stream.name(id,[{filename:p,longname:'',attrs:{}}]));for(const e of ['STAT','LSTAT'])on(e,(id,p)=>stream.attrs(id,attrs(fs.statSync(local(p)))));on('FSTAT',(id,h)=>stream.attrs(id,attrs(fs.fstatSync(get(h).fd))));on('OPENDIR',(id,p)=>handle(id,{path:local(p)}));on('READDIR',(id,h)=>{const e=get(h);if(e.read){stream.status(id,1);return;}e.read=true;stream.name(id,fs.readdirSync(e.path).map(n=>({filename:n,longname:n,attrs:attrs(fs.statSync(path.join(e.path,n)))})));});
  on('OPEN',(id,p,flags)=>handle(id,{fd:fs.openSync(local(p),flags&8?(flags&32?'wx':flags&16?'w+':'a+'):'r')}));on('CLOSE',(id,h)=>{const e=get(h);if(e?.fd!==undefined)fs.closeSync(e.fd);handles.delete(h.toString('hex'));stream.status(id,0);});on('READ',(id,h,offset,length)=>{const b=Buffer.alloc(length);const n=fs.readSync(get(h).fd,b,0,length,offset);if(n)stream.data(id,b.subarray(0,n));else stream.status(id,1);});on('WRITE',(id,h,offset,b)=>{fs.writeSync(get(h).fd,b,0,b.length,offset);stream.status(id,0);});on('MKDIR',(id,p)=>{fs.mkdirSync(local(p));stream.status(id,0);});on('RMDIR',(id,p)=>{fs.rmdirSync(local(p));stream.status(id,0);});on('REMOVE',(id,p)=>{fs.unlinkSync(local(p));stream.status(id,0);});on('RENAME',(id,a,b)=>{fs.renameSync(local(a),local(b));stream.status(id,0);});on('SETSTAT',(id,p,a)=>{if(a.mode!==undefined)fs.chmodSync(local(p),a.mode);stream.status(id,0);});
 }
 const key=generateKeyPairSync('ec',{namedCurve:'prime256v1',privateKeyEncoding:{format:'pem',type:'sec1'},publicKeyEncoding:{format:'pem',type:'spki'}}).privateKey;
 const server=new Server({hostKeys:[key]},client=>{clients.add(client);client.on('close',()=>clients.delete(client));client.on('error',()=>{});client.on('authentication',c=>c.method==='password'&&c.username==='fixture'&&c.password===login?c.accept():c.reject());client.on('ready',()=>client.on('session',accept=>{const session=accept();let pty=false;session.on('pty',accept=>{pty=true;accept();});session.on('sftp',accept=>sftp(accept()));session.on('exec',(accept,reject,info)=>{const channel=accept();let cmd=info.command;observations.push({cmd,pty});if(options.disconnectExecution && cmd.includes('disconnect-fixture')){client.destroy();return;}if(cmd.startsWith("rm -rf -- '/tmp/ssh-batch-") && (options.cleanupFailure || options.cleanupRequiresElevation)){channel.stderr.write('fixture cleanup denied');channel.exit(1);channel.end();return;}if(options.cleanupFailure && /(?:sudo|su).*rm -rf --/.test(cmd)){channel.stderr.write('fixture cleanup denied');channel.exit(1);channel.end();return;}let child;const start=()=>{child=spawn('/bin/sh',['-c',map(cmd)],{cwd:directory,detached:true,env:{...process.env,HOME:directory}});child.stdin.on('error',()=>{});channel.on('data',data=>child.stdin.write(data));child.stdout.pipe(channel,{end:false});child.stderr.pipe(channel.stderr,{end:false});child.on('exit',code=>{if(!(options.mkdirUnknownStatus&&cmd.startsWith('umask 077; mkdir ')))channel.exit(code??1);channel.end();});};channel.on('close',()=>{if(child?.pid){try{process.kill(-child.pid,'SIGKILL');}catch{}}});if(cmd.startsWith('sudo ')){cmd=cmd.slice(cmd.indexOf('sh -c '));channel.stderr.write('__TERMPILOT_PASSWORD__');channel.once('data',v=>{if(v.toString().trim()!==rootPassword){channel.stderr.write('denied');channel.exit(1);channel.end();}else start();});}else if(cmd.startsWith('su - root -c ')){assert.equal(pty,true,'su must request a PTY');cmd='sh -c '+cmd.slice('su - root -c '.length);channel.write('Password:');channel.once('data',v=>{if(v.toString().trim()!==rootPassword){channel.exit(1);channel.end();}else start();});}else start();});}));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;
 return {directory,port,observations,local,disconnect:()=>{for(const c of clients)c.end();},config:{hostname:'127.0.0.1',port,username:'fixture',password:login,authentication:'password',knownHostsFile:path.join(directory,'known_hosts'),autoAcceptHostKeys:false,batchElevation:'none',elevationPassword:rootPassword},close:async()=>{for(const c of clients)c.destroy();await new Promise(r=>server.close(r));fs.rmSync(directory,{recursive:true,force:true});}};
}
async function run(f,job,options={}){
 const events=[];const child=spawn(engine,['batch'],{stdio:['pipe','pipe','pipe']});let stderr='';child.stderr.on('data',d=>stderr+=d);const lines=readline.createInterface({input:child.stdout});lines.on('line',l=>{const e=JSON.parse(l);events.push(e);if(e.event?.type==='hostKeyPrompt')child.stdin.write(JSON.stringify({type:'hostKeyResponse',promptID:e.event.promptID,accepted:options.accept!==false})+'\n');if(options.onEvent)options.onEvent(e,child);});child.stdin.write(JSON.stringify({job,targets:options.targets??[{id:'fixture',config:{...f.config,batchElevation:options.elevation??'none'}}],historyDirectory:path.join(f.directory,'history'),historyJobId:options.historyJobId??'',backgroundAction:options.backgroundAction??''})+'\n');const code=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill('SIGKILL');reject(Error('Batch timed out: '+stderr));},20000);child.on('exit',code=>{clearTimeout(timer);resolve(code);});});if(!options.interrupt){assert.equal(code,0,stderr);assert.ok(events.some(e=>e.type==='batchFinished'),stderr);}
 if(!options.allowCleanupFailure && job.executionMode!=='background' && !options.backgroundAction){const workspaces=new Map(events.filter(e=>e.stage==='workspace').map(e=>[e.targetId,e]));for(const event of workspaces.values()){assert.equal(event.cleanupStatus,'success','temporary workspace must be cleaned on every outcome');assert.match(event.remoteWorkDirectory,/^\/tmp\/ssh-batch-[0-9a-f-]{36}$/);if(event.port===f.port)assert.equal(fs.existsSync(f.local(event.remoteWorkDirectory)),false);assert.ok(events.indexOf(event)<events.findIndex(e=>e.targetId===event.targetId&&e.stage==='finished'),'cleanup must complete before final status');}}
 return events;
}
const finished=e=>e.filter(v=>v.stage==='finished');
if(process.argv.includes('--fixture'))void fixture().then(f=>{
 process.stdout.write(JSON.stringify({directory:f.directory,port:f.port})+'\n');
 process.stdin.resume();process.stdin.on('end',()=>void f.close().then(()=>process.exit(0)));
});
test('batch host-key policy follows automatic acceptance and preserves manual confirmation',{timeout:30000},async()=>{
 const f=await fixture();try {
  const job={kind:'check'};
  let events=await run(f,job,{accept:false});
  assert.equal(finished(events)[0].status,'failed');
  assert.equal(events.filter(e=>e.event?.type==='hostKeyPrompt').length,1);
  assert.equal(f.observations.length,0);
  assert.equal(fs.existsSync(f.config.knownHostsFile),false);

  f.config.autoAcceptHostKeys=true;
  events=await run(f,job,{accept:false});
  assert.equal(finished(events)[0].status,'success');
  assert.ok(!events.some(e=>e.event?.type==='hostKeyPrompt'));
  assert.ok(fs.readFileSync(f.config.knownHostsFile,'utf8').includes(`[127.0.0.1]:${f.port}`));

  f.config.autoAcceptHostKeys=false;
  events=await run(f,job,{accept:false});
  assert.equal(finished(events)[0].status,'success');
  assert.ok(!events.some(e=>e.event?.type==='hostKeyPrompt'),'matching saved keys need no prompt');
  fs.unlinkSync(f.config.knownHostsFile);
  events=await run(f,job);
  assert.equal(finished(events)[0].status,'success');
  assert.equal(events.filter(e=>e.event?.type==='hostKeyPrompt').length,1);
  assert.equal(events.find(e=>e.event?.type==='hostKeyPrompt').event.detail.hasHostPattern,false);
 }finally{await f.close();}
});
test('batch host-key changes still require confirmation with automatic acceptance enabled',{timeout:30000},async()=>{
 const f=await fixture(),other=await fixture();try {
  other.config.autoAcceptHostKeys=true;
  const seed=await run(other,{kind:'check'},{accept:false});
  assert.equal(finished(seed)[0].status,'success');
  const oldKey=fs.readFileSync(other.config.knownHostsFile,'utf8')
   .replace(`[127.0.0.1]:${other.port}`,`[127.0.0.1]:${f.port}`);
  fs.writeFileSync(f.config.knownHostsFile,oldKey);
  f.config.autoAcceptHostKeys=true;
  const events=await run(f,{kind:'check'},{accept:false});
  assert.equal(finished(events)[0].status,'failed');
  const prompts=events.filter(e=>e.event?.type==='hostKeyPrompt');
  assert.equal(prompts.length,1);
  assert.equal(prompts[0].event.detail.hasHostPattern,true);
  assert.equal(f.observations.length,0);
  assert.equal(fs.readFileSync(f.config.knownHostsFile,'utf8'),oldKey);
 }finally{await f.close();await other.close();}
});
test('batch commands support none, sudo, su; authenticate each temporary target and redact reports',{timeout:70000},async()=>{const f=await fixture();try{for(const elevation of ['none','sudo','su']){const e=await run(f,{kind:'execute',script:{body:'\uFEFFprintf "hello %s" "$1"\r\n',args:['quoted ; argument'] }},{elevation});assert.equal(finished(e)[0].status,'success');assert.equal(e.find(v=>v.stage==='execute'&&v.status==='success').stdout,'hello quoted ; argument');const report=e.find(v=>v.type==='batchStarted').reportDirectory;assert.ok(!fs.readFileSync(path.join(report,'events.jsonl'),'utf8').includes(login));assert.ok(!fs.readFileSync(path.join(report,'events.jsonl'),'utf8').includes(rootPassword));}}finally{await f.close();}});
test('upload conflict policies preserve conflict host list and apply permissions',{timeout:70000},async()=>{const f=await fixture();try{const input=path.join(f.directory,'input');const remote=path.join(f.directory,'remote');fs.mkdirSync(remote);fs.writeFileSync(input,'new');const dest=path.join(remote,'input');for(const overwrite of ['skip','overwrite','backup']){fs.writeFileSync(dest,'old');const e=await run(f,{kind:'upload',stepTimeout:0,localPaths:[input],remoteDirectory:remote,overwrite,fileMode:'0640'},{elevation:'sudo'});assert.equal(finished(e)[0].status,'success');assert.ok(e.some(v=>v.stage==='conflict'&&v.ip==='127.0.0.1'&&v.policy===overwrite));assert.equal(fs.readFileSync(dest,'utf8'),overwrite==='skip'?'old':'new');if(overwrite!=='skip')assert.equal(fs.statSync(dest).mode&0o777,0o640);if(overwrite==='backup')assert.ok(fs.readdirSync(remote).some(n=>n.includes('.termpilot-backup-')&&fs.readFileSync(path.join(remote,n),'utf8')==='old'));}}finally{await f.close();}});
test('collection prepares, verifies SHA-256, names by IP/time and runs cleanup after success',{timeout:30000},async()=>{const f=await fixture();try{const out=path.join(f.directory,'out');const marker=path.join(f.directory,'cleaned');const e=await run(f,{kind:'collect',stepTimeout:0,before:{body:'printf collected > "$REMOTE_WORK_DIR/report.log"'},remotePaths:['${REMOTE_WORK_DIR}/report.log','${REMOTE_WORK_DIR}/report.log'],localDirectory:out,after:{body:`printf cleaned > '${marker}'` }},{elevation:'su'});assert.equal(finished(e)[0].status,'success');const files=fs.readdirSync(out);assert.equal(files.length,2);assert.equal(new Set(e.filter(v=>v.stage==='collect'&&v.status==='success').map(v=>v.stepId)).size,2);assert.ok(files.every(n=>/^127\.0\.0\.1-\d{8}-\d{9}Z-report(-1)?\.log$/.test(n)));for(const n of files)assert.equal(fs.readFileSync(path.join(out,n),'utf8'),'collected');assert.ok(e.filter(v=>v.stage==='collect'&&v.status==='success').every(v=>v.sha256.length===64));assert.equal(fs.readFileSync(marker,'utf8'),'cleaned');}finally{await f.close();}});
test('collection failures remove the workspace while user cleanup policies stay independent',{timeout:60000},async()=>{const f=await fixture();try{const out=path.join(f.directory,'out');const marker=path.join(f.directory,'cleanup');let e=await run(f,{kind:'collect',before:{body:'printf evidence > "$REMOTE_WORK_DIR/evidence"'},remotePaths:['${REMOTE_WORK_DIR}/missing'],localDirectory:out,after:{body:`touch '${marker}'`}});assert.equal(finished(e)[0].status,'failed');assert.equal(fs.existsSync(marker),false);assert.ok(e.some(v=>v.stage==='cleanup'&&v.status==='skipped'));e=await run(f,{kind:'collect',before:{body:'exit 7'},remotePaths:['${REMOTE_WORK_DIR}/missing'],localDirectory:out,cleanupPolicy:'always',after:{body:`touch '${marker}'`}});assert.equal(finished(e)[0].status,'failed');assert.ok(fs.existsSync(marker));assert.ok(!e.some(v=>v.stage==='collect'));const src=path.join(f.directory,'source.log');fs.writeFileSync(src,'source');e=await run(f,{kind:'collect',remotePaths:[src],localDirectory:out,after:{body:'exit 9'}});assert.equal(e.find(v=>v.stage==='collection').status,'success');assert.equal(finished(e)[0].status,'failed');assert.ok(finished(e)[0].message.includes('Cleanup failed'));assert.equal(fs.existsSync(src),true);}finally{await f.close();}});
test('rejected host key runs no commands; cancellation skips user cleanup but removes workspace',{timeout:30000},async()=>{const f=await fixture();try{let e=await run(f,{kind:'execute',script:{body:'echo never'}},{accept:false});assert.equal(finished(e)[0].status,'failed');assert.equal(f.observations.length,0);const marker=path.join(f.directory,'unexpected');e=await run(f,{kind:'collect',before:{body:'sleep 20'},remotePaths:[marker],localDirectory:path.join(f.directory,'out'),cleanupPolicy:'always',after:{body:`touch '${marker}'`}},{onEvent:(e,c)=>{if(e.stage==='prepare'&&e.status==='running')setTimeout(()=>c.stdin.write('{"type":"cancel"}\n'),100);}});assert.equal(finished(e)[0].status,'cancelled');assert.equal(fs.existsSync(marker),false);}finally{await f.close();}});
test('bounded multi-host execution and stop-on-failure leave unscheduled hosts untouched',{timeout:40000},async()=>{const a=await fixture(),b=await fixture();try{const targets=[{id:'a',config:a.config},{id:'b',config:b.config}];let e=await run(a,{kind:'execute',concurrency:2,script:{body:'printf multi'}},{targets});assert.deepEqual(finished(e).map(e=>e.status),['success','success']);assert.equal(e.filter(e=>e.stage==='execute'&&e.stdout==='multi').length,2);b.observations.length=0;e=await run(a,{kind:'execute',concurrency:1,stopOnFailure:true,script:{body:'exit 4'}},{targets});assert.equal(finished(e).find(e=>e.targetId==='a').status,'failed');assert.equal(finished(e).find(e=>e.targetId==='b').status,'skipped');assert.equal(b.observations.length,0);}finally{await a.close();await b.close();}});
test('directory uploads verify every file and apply separate directory/file modes',{timeout:30000},async()=>{const f=await fixture();try{const input=path.join(f.directory,'tree'),remote=path.join(f.directory,'remote');fs.mkdirSync(path.join(input,'nested'),{recursive:true});fs.mkdirSync(remote);fs.writeFileSync(path.join(input,'nested','日志.txt'),'tree data');const e=await run(f,{kind:'upload',stepTimeout:0,localPaths:[input],remoteDirectory:remote,fileMode:'0640',directoryMode:'0750',recursivePermissions:true},{elevation:'su'});assert.equal(finished(e)[0].status,'success');assert.equal(fs.readFileSync(path.join(remote,'tree','nested','日志.txt'),'utf8'),'tree data');assert.equal(fs.statSync(path.join(remote,'tree','nested')).mode&0o777,0o750);assert.equal(fs.statSync(path.join(remote,'tree','nested','日志.txt')).mode&0o777,0o640);}finally{await f.close();}});
test('connection checks report authentication and elevation failures in their own phases',{timeout:30000},async()=>{
 const f=await fixture();try {
  for(const [expectedStage,config] of [['authenticate',{...f.config,password:'wrong-login'}],['elevation',{...f.config,batchElevation:'sudo',elevationPassword:'wrong-root'}]]) {
   const events=await run(f,{kind:'check'},{targets:[{id:'failed',config}]});
   const latest=stage=>events.filter(e=>e.targetId==='failed'&&e.stage===stage).at(-1);
   assert.equal(latest(expectedStage).status,'failed');assert.equal(latest('finished').status,'failed');
   if(expectedStage==='authenticate')assert.equal(latest('elevation').status,'skipped');
   else assert.equal(latest('authenticate').status,'success');
  }
 } finally {await f.close();}
});

test('zero step timeout allows long commands and cancellation; positive timeout still fails',{timeout:30000},async()=>{
 const f=await fixture();try {
  let e=await run(f,{kind:'execute',stepTimeout:0,script:{body:'sleep 1.2; printf unlimited'}});
  assert.equal(finished(e)[0].status,'success');assert.equal(e.find(v=>v.stage==='execute'&&v.status==='success').stdout,'unlimited');
  e=await run(f,{kind:'execute',stepTimeout:1,script:{body:'sleep 3'}});
  assert.equal(finished(e)[0].status,'failed');assert.match(finished(e)[0].message,/timed out/);
  e=await run(f,{kind:'execute',stepTimeout:0,script:{body:'sleep 20'}},{onEvent:(e,c)=>{if(e.stage==='execute'&&e.status==='running')setTimeout(()=>c.stdin.write('{"type":"cancel"}\n'),100);}});
  assert.equal(finished(e)[0].status,'cancelled');
 } finally {await f.close();}
});


test('workspace cleanup runs after upload failure and deletes partial staged data',{timeout:30000},async()=>{
 const f=await fixture();try{const input=path.join(f.directory,'input');fs.writeFileSync(input,'staged');fs.writeFileSync(path.join(f.directory,'missing'),'blocks destination parent');const e=await run(f,{kind:'upload',localPaths:[input],remoteDirectory:path.join(f.directory,'missing','remote')});assert.equal(finished(e)[0].status,'failed');assert.equal(e.filter(e=>e.stage==='workspace').at(-1).cleanupStatus,'success');}finally{await f.close();}
});
test('workspace cleanup uses per-step elevation when ordinary removal is denied',{timeout:30000},async()=>{
 const f=await fixture({cleanupRequiresElevation:true});try{const e=await run(f,{kind:'execute',script:{body:'mkdir "$REMOTE_WORK_DIR/private"; touch "$REMOTE_WORK_DIR/private/file"',elevation:'su'}});assert.equal(finished(e)[0].status,'success');assert.ok(f.observations.some(e=>e.cmd.startsWith('su - root -c ')&&e.cmd.includes('rm -rf --')));}finally{await f.close();}
});
test('cleanup failure is reported instead of silently completing or hiding the original failure',{timeout:30000},async()=>{
 const f=await fixture({cleanupFailure:true});try{for(const body of ['printf success','exit 4']){const e=await run(f,{kind:'execute',script:{body}},{allowCleanupFailure:true,elevation:'sudo'});const workspace=e.filter(v=>v.stage==='workspace').at(-1);assert.equal(workspace.cleanupStatus,'failed');assert.equal(workspace.status,'failed');assert.equal(finished(e)[0].status,'failed');assert.match(finished(e)[0].message,/Temporary directory cleanup failed/);if(body==='exit 4')assert.match(finished(e)[0].message,/execute script failed/);assert.ok(fs.existsSync(f.local(workspace.remoteWorkDirectory)));}}finally{await f.close();}
});
test('workspace cleanup does not follow symlinks or remove files outside the task directory',{timeout:30000},async()=>{
 const f=await fixture();try{const outside=path.join(f.directory,'keep');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'evidence'),'keep');const e=await run(f,{kind:'execute',script:{body:`rmdir "$REMOTE_WORK_DIR"; ln -s '${outside}' "$REMOTE_WORK_DIR"; exit 7`}});assert.equal(finished(e)[0].status,'failed');assert.equal(fs.readFileSync(path.join(outside,'evidence'),'utf8'),'keep');}finally{await f.close();}
});

test('connection loss reports cleanup failure and keeps the temporary path available for diagnosis',{timeout:30000},async()=>{
 const f=await fixture({disconnectExecution:true});try{const events=await run(f,{kind:'execute',script:{body:'printf disconnect-fixture'}},{allowCleanupFailure:true});const workspace=events.filter(e=>e.stage==='workspace').at(-1);assert.equal(workspace.cleanupStatus,'failed');assert.match(finished(events)[0].message,/Temporary directory cleanup failed/);assert.ok(fs.existsSync(f.local(workspace.remoteWorkDirectory)));const report=events.find(e=>e.type==='batchStarted').reportDirectory;const persisted=fs.readFileSync(path.join(report,'events.jsonl'),'utf8').trim().split('\n').map(JSON.parse);assert.equal(persisted.filter(e=>e.stage==='workspace').at(-1).cleanupStatus,'failed');}finally{await f.close();}
});

test('workspace is removed when mkdir completed but the server omitted its exit status',{timeout:30000},async()=>{
 const f=await fixture({mkdirUnknownStatus:true});try{const events=await run(f,{kind:'execute',script:{body:'printf never'}});assert.equal(finished(events)[0].status,'failed');assert.ok(!events.some(e=>e.stage==='execute'));assert.equal(events.filter(e=>e.stage==='workspace').at(-1).cleanupStatus,'success');}finally{await f.close();}
});

const backgroundJob=body=>({kind:'execute',executionMode:'background',stepTimeout:0,script:{body}});
test('batch Bash defaults support pipefail and arrays in foreground and background',{timeout:30000},async()=>{
 const f=await fixture();try {
  const body='#!/usr/bin/env bash\nset -euo pipefail\n[[ "$BASH" == /bin/bash ]]\nitems=(alpha beta)\nprintf "%s" "${items[1]}"';
  for(const shell of [undefined,'','/bin/bash']) {
   const script={body,...(shell===undefined?{}:{shell})};
   let events=await run(f,{kind:'execute',script});
   assert.equal(finished(events)[0].status,'success',JSON.stringify(events));
   assert.equal(events.find(e=>e.stage==='execute'&&e.status==='success').stdout,'beta');
   const submitted=await run(f,{...backgroundJob(body),script});
   events=await backgroundDone(f,submitted.find(e=>e.type==='batchStarted').jobId);
   assert.equal(finished(events)[0].status,'success',JSON.stringify(events));
   assert.equal(events.find(e=>e.stage==='execute').stdout,'beta');
  }
 }finally{await f.close();}
});
test('batch interpreter overrides and pipefail failure status are preserved',{timeout:30000},async()=>{
 const f=await fixture();try {
  for(const executionMode of ['foreground','background']) {
   for(const script of [
    {shell:'/bin/sh',body:'test "${BASH:-/bin/sh}" = /bin/sh || exit 47; printf explicit-sh'},
    {body:'set -euo pipefail\nfalse | true\nprintf should-not-run'},
   ]) {
    let events=await run(f,{kind:'execute',executionMode,script});
    if(executionMode==='background')events=await backgroundDone(f,events.find(e=>e.type==='batchStarted').jobId);
    const step=events.find(e=>e.stage==='execute'&&e.status!=='running');
    assert.equal(finished(events)[0].status,script.shell?'success':'failed',JSON.stringify(events));
    assert.equal(step.stdout,script.shell?'explicit-sh':'');
    assert.equal(step.exitCode,script.shell?0:1);
   }
  }
 }finally{await f.close();}
});
async function backgroundQuery(f,id,action='status',options={}) {return run(f,{kind:'execute',script:{body:':'}},{...options,historyJobId:id,backgroundAction:action});}
async function backgroundDone(f,id,options={}) {
 const deadline=Date.now()+15000;let events;
 while(Date.now()<deadline){events=await backgroundQuery(f,id,'status',options);if(finished(events).every(e=>!['running','pending'].includes(e.status)))return events;await new Promise(r=>setTimeout(r,100));}
 throw Error('Background task did not finish: '+JSON.stringify(events));
}
test('background survives client termination and transport loss; history reconnect retrieves logs without replay',{timeout:45000},async()=>{
 const f=await fixture();try {
  const marker=path.join(f.directory,'once');
  const first=await run(f,backgroundJob(`printf 'started\n'; sleep 2; printf '中文 result\n'; printf once >> '${marker}'`),{interrupt:true,onEvent:(event,child)=>{if(event.stage==='execute'){f.disconnect();child.kill('SIGKILL');}}});
  const start=first.find(e=>e.type==='batchStarted');assert.ok(start.backgroundTasks[0].remoteTaskId);
  const receipt=JSON.parse(fs.readFileSync(path.join(start.reportDirectory,'background.json'),'utf8'));
  assert.equal(receipt[0].remoteTaskId,start.backgroundTasks[0].remoteTaskId);
  assert.ok(!JSON.stringify(receipt).includes(login));assert.ok(!JSON.stringify(receipt).includes(rootPassword));
  const final=await backgroundDone(f,start.jobId);assert.equal(finished(final)[0].status,'success',JSON.stringify(final));
  assert.match(final.find(e=>e.stage==='execute').stdout,/中文 result/);
  const work=final.find(e=>e.stage==='workspace');assert.equal(work.cleanupStatus,'success');assert.equal(fs.existsSync(work.remoteWorkDirectory),false);
  const again=await backgroundQuery(f,start.jobId);assert.equal(finished(again)[0].status,'success');assert.equal(fs.readFileSync(marker,'utf8'),'once');
  const logs=await backgroundQuery(f,start.jobId,'logs');for(const entry of logs.filter(e=>e.stage==='logs'))assert.ok(fs.existsSync(entry.localPath));
  assert.match(fs.readFileSync(logs.find(e=>e.stepId==='stdout').localPath,'utf8'),/中文 result/);
 }finally{await f.close();}
});
test('background sudo and su preserve elevation; failures, remote timeout and explicit cancellation clean the workspace',{timeout:90000},async()=>{
 const f=await fixture();try {
  for(const elevation of ['sudo','su']) {
   const first=await run(f,backgroundJob('sleep 0.3; printf elevated; exit 7'),{elevation});const id=first.find(e=>e.type==='batchStarted').jobId;
   const final=await backgroundDone(f,id,{elevation});assert.equal(finished(final)[0].status,'failed',JSON.stringify(final));assert.equal(finished(final)[0].exitCode,7);assert.equal(final.find(e=>e.stage==='workspace').cleanupStatus,'success');
  }
  let first=await run(f,{...backgroundJob('sleep 20'),stepTimeout:1});let id=first.find(e=>e.type==='batchStarted').jobId;
  let final=await backgroundDone(f,id);assert.equal(finished(final)[0].timedOut,true,JSON.stringify(final));assert.equal(final.find(e=>e.stage==='workspace').cleanupStatus,'success');
  first=await run(f,backgroundJob('sleep 20'));id=first.find(e=>e.type==='batchStarted').jobId;
  await backgroundQuery(f,id,'cancel');final=await backgroundDone(f,id);assert.equal(finished(final)[0].status,'cancelled');assert.equal(final.find(e=>e.stage==='workspace').cleanupStatus,'success');
 }finally{await f.close();}
});
test('background log tail is bounded; complete logs preserve chunks and redact known passwords',{timeout:45000},async()=>{
 const f=await fixture();try {
  const body=`python3 -c 'import sys;sys.stdout.write("x"*131060+"${login}"+"中"*30000);sys.stderr.write("stderr-end")'`;
  const first=await run(f,backgroundJob(body));const id=first.find(e=>e.type==='batchStarted').jobId;
  const final=await backgroundDone(f,id);const output=final.find(e=>e.stage==='execute');assert.equal(output.stdoutTruncated,true);assert.equal(output.stderr,'stderr-end');
  const logs=await backgroundQuery(f,id,'logs');const full=fs.readFileSync(logs.find(e=>e.stepId==='stdout').localPath,'utf8');assert.equal(full,'x'.repeat(131060)+'[redacted]'+'中'.repeat(30000));
 }finally{await f.close();}
});
test('stopping a background query does not mark unqueried remote hosts cancelled',{timeout:45000},async()=>{
 const a=await fixture(),b=await fixture();try {
  const targets=[{id:'a',config:a.config},{id:'b',config:b.config}];
  const submitted=await run(a,backgroundJob('sleep 2; printf survived'),{targets});
  const id=submitted.find(e=>e.type==='batchStarted').jobId;
  const interrupted=await run(a,{kind:'execute',concurrency:1,script:{body:':'}},{targets,historyJobId:id,backgroundAction:'status',onEvent:(event,child)=>{
   if(event.targetId==='a'&&event.stage==='authenticate'&&event.status==='running')child.stdin.write('{"type":"cancel"}\n');
  }});
  const unqueried=finished(interrupted).find(e=>e.targetId==='b');
  assert.equal(unqueried.status,'unknown');assert.equal(unqueried.remoteStateUnknown,true);
  const complete=await backgroundDone(a,id,{targets});
  assert.ok(finished(complete).every(e=>e.status==='success'),JSON.stringify(complete));
 }finally{await a.close();await b.close();}
});
