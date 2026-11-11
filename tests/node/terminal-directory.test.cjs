'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
const {spawn}=require('node:child_process');const {generateKeyPairSync}=require('node:crypto');
const {Server}=require('ssh2');const readline=require('node:readline');
const engine=process.env.TERMPILOT_TEST_ENGINE||path.resolve(__dirname,'../../target/debug/termpilot-engine');
async function fixture(){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'TermPilot-terminal-cwd-'));
 const clients=new Set();const commands=[];const input=[];
 const stack=[{pid:100,path:'/home/fixture',user:'fixture'}];let hidden=false;
 const key=generateKeyPairSync('ec',{namedCurve:'prime256v1',privateKeyEncoding:{format:'pem',type:'sec1'},publicKeyEncoding:{format:'pem',type:'spki'}}).privateKey;
 const server=new Server({hostKeys:[key]},client=>{
  clients.add(client);client.on('error',()=>{});client.on('close',()=>clients.delete(client));
  client.on('authentication',c=>c.username==='fixture'&&c.method==='password'&&c.password==='fixture-password'?c.accept():c.reject());
  client.on('ready',()=>client.on('session',accept=>{
   const session=accept();session.on('pty',accept=>accept());session.on('env',accept=>accept?.());
   session.on('shell',accept=>{
    const shell=accept();shell.write('fixture prompt> ');let pending='';
    shell.on('data',bytes=>{input.push(bytes.toString());pending+=bytes;let n;while((n=pending.indexOf('\r'))>=0){const line=pending.slice(0,n);pending=pending.slice(n+1);if(line==='sudo -i')stack.push({pid:203,path:'/root',user:'root'});else if(line==='su - app')stack.push({pid:305,path:'/home/app',user:'app'});else if(line==='exit'&&stack.length>1)stack.pop();else if(line.startsWith('cd '))stack.at(-1).path=line.slice(3);shell.write('done:'+line+'\r\nfixture prompt> ');}});
   });
   session.on('exec',(accept,reject,info)=>{
    const stream=accept();const cmd=info.command;commands.push(cmd);const elevated=cmd.startsWith('sudo ')||cmd.startsWith('su - root -c ');
    const finish=(text,code=0)=>{stream.write(text);stream.exit(code);stream.end();};
    const execute=()=>{
     if(cmd.includes('# termpilot-terminal-processes')){
      const root=`100 10 100 ${stack.length>1?200:100} 1 123 bash\n`;
      let rows='';if(stack.length>1&&!(hidden&&!elevated))rows=`200 100 200 200 1 200 sudo\n201 200 201 ${stack.length>2?304:203} 2 201 sudo\n203 201 203 ${stack.length>2?304:203} 2 203 bash\n`;
      if(stack.length>2&&!(hidden&&!elevated))rows+='304 203 304 304 2 304 su\n305 304 304 304 2 305 bash\n';
      // Another PTY under a different SSH connection and a background job.
      finish('__TP_PARENT__10\n'+root+rows+'800 100 800 100 1 800\n900 99 900 900 9 900\n');
     }else if(cmd.includes('# termpilot-terminal-context')){
      const pid=Number(cmd.match(/# termpilot-terminal-context (\d+)/)[1]);const target=stack.find(v=>v.pid===pid);
      if(!target){finish('',1);}else finish('\x1eTP_USER:'+target.user+'\x1f\x1eTP_CWD:'+(pid!==100&&!elevated?'':target.path)+'\x1f');
     }else if(cmd==='pwd')finish('/home/fixture\n');else finish('',1);
    };
    if(elevated){stream.stderr.write('__TERMPILOT_PASSWORD__');stream.once('data',data=>{assert.equal(data.toString().trim(),'fixture-root');execute();});}else execute();
   });
  }));
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const child=spawn(engine,['ssh'],{stdio:['pipe','pipe','pipe']});const frames=[];const waits=[];let stderr='';child.stderr.on('data',b=>stderr+=b);
 const send=value=>child.stdin.write(JSON.stringify(value)+'\n');
 readline.createInterface({input:child.stdout}).on('line',line=>{const frame=JSON.parse(line);frames.push(frame);for(const w of [...waits])if(w.predicate(frame)){waits.splice(waits.indexOf(w),1);clearTimeout(w.timer);w.resolve(frame);}});
 const wait=predicate=>{const existing=frames.find(predicate);if(existing)return Promise.resolve(existing);return new Promise((resolve,reject)=>{const w={predicate,resolve,timer:setTimeout(()=>reject(Error('Timeout '+stderr+' '+JSON.stringify(frames))),10000)};waits.push(w);});};
 send({type:'connect',config:{hostname:'127.0.0.1',port:server.address().port,username:'fixture',authentication:'password',password:'fixture-password',autoAcceptHostKeys:true,knownHostsFile:path.join(directory,'known_hosts'),sessionID:'terminal-one'}});
 await wait(f=>f.type==='log'&&f.status==='connected');await wait(f=>f.type==='cwd');
 let next=1;
 async function open(elevated,method='sudo'){
  const start=frames.length;send({type:'sftpOpen',config:{execOnly:true,sourceSessionID:'terminal-one',usesSudo:elevated,elevationMethod:method,elevationPassword:'fixture-root'}});
  await wait(f=>frames.indexOf(f)>=start&&f.type==='sftpReady');
 }
 async function request(sourceSessionID='terminal-one'){
  const id=next++;send({type:'sftpRequest',channel:'files',request:{id,action:'terminalCWD',sourceSessionID}});
  const reply=await wait(f=>f.type==='sftpResponse'&&f.message.id===id);if(!reply.message.ok)throw Error(reply.message.error);return reply.message.result.path;
 }
 async function type(line){const start=frames.length;send({type:'data',data:Buffer.from(line+'\r').toString('base64')});await wait(f=>frames.indexOf(f)>=start&&f.type==='data'&&Buffer.from(f.data,'base64').toString().includes('done:'+line));}
 async function account(user){await wait(f=>f.type==='user'&&f.username===user);}
 return{open,request,type,account,commands,input,hide(value){hidden=value;},close:async()=>{child.stdin.end();await new Promise(r=>child.exitCode!==null?r():child.once('exit',r));for(const w of waits)clearTimeout(w.timer);for(const c of clients)c.destroy();await new Promise(r=>server.close(r));fs.rmSync(directory,{recursive:true,force:true});}};
}
test('terminal directory follows sudo new PTY, nested su, private Unicode paths and exit without injecting input',{timeout:30000},async()=>{
 const f=await fixture();try{
  await f.open(true);assert.equal(await f.request(),'/home/fixture');
  await f.type('sudo -i');assert.equal(await f.request(),'/root');await f.account('root');
  await f.type('cd /root/private logs/中文');assert.equal(await f.request(),'/root/private logs/中文');
  await f.type('su - app');assert.equal(await f.request(),'/home/app');await f.account('app');
  await f.type('cd /srv/app');assert.equal(await f.request(),'/srv/app');
  await f.type('exit');assert.equal(await f.request(),'/root/private logs/中文');
  await f.open(true,'su');assert.equal(await f.request(),'/root/private logs/中文');
  await f.type('exit');assert.equal(await f.request(),'/home/fixture');
  await assert.rejects(f.request('another-tab'),/identify this terminal/);
  assert.equal(f.input.join(''),'sudo -i\rcd /root/private logs/中文\rsu - app\rcd /srv/app\rexit\rexit\r');
  assert.ok(!f.commands.some(c=>c.startsWith('cd -- ')));
 }finally{await f.close();}
});
test('permission denial and hidden foreground processes never return the cached login directory',{timeout:30000},async()=>{
 const f=await fixture();try{
  await f.open(false);assert.equal(await f.request(),'/home/fixture');
  await f.type('sudo -i');await assert.rejects(f.request(),/elevation and permissions/);
  f.hide(true);await assert.rejects(f.request(),/foreground job/);
  await f.open(true);assert.equal(await f.request(),'/root');
 }finally{await f.close();}
});
