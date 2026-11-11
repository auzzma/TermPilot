'use strict';
// Optional real OpenSSH acceptance: use only an isolated fixture server.
const {test}=require('node:test');const assert=require('node:assert/strict');
const {spawn}=require('node:child_process');const fs=require('node:fs');const path=require('node:path');const os=require('node:os');const readline=require('node:readline');
const engine=process.env.TERMPILOT_TEST_ENGINE||path.resolve(__dirname,'../../target/debug/termpilot-engine');
const port=Number(process.env.TERMPILOT_CWD_FIXTURE_PORT||0);
async function terminal(nativeBroker=false){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'TermPilot-live-cwd-'));const frames=[];let output='',stderr='';
 const child=spawn(engine,[nativeBroker?'ssh-broker':'ssh'],{stdio:['pipe','pipe','pipe']});child.stderr.on('data',b=>stderr+=b);
 let transport, socketPath;const probes=[];
 let send=v=>child.stdin.write(JSON.stringify(v)+'\n');
 const receive=stream=>readline.createInterface({input:stream}).on('line',line=>{const f=JSON.parse(line);frames.push(f);if(f.type==='data')output+=Buffer.from(f.data,'base64').toString();});
 async function until(predicate){const until=Date.now()+15000;while(!predicate()){if(Date.now()>until)throw Error('Timed out '+stderr+' output='+output+' frames='+JSON.stringify(frames));await new Promise(r=>setTimeout(r,20));}}
 const id=require('node:crypto').randomUUID();
 const config={hostname:'127.0.0.1',port,username:'fixture',password:'fixture-password',authentication:'password',autoAcceptHostKeys:true,knownHostsFile:path.join(directory,'known_hosts'),sessionID:id,connectionID:id};
 if(nativeBroker){
  child.stdin.end(JSON.stringify(config)+'\n');
  socketPath=path.join('/tmp',`TermPilot-${process.getuid()}`,require('node:crypto').createHash('sha256').update(id).digest('hex').slice(0,32)+'.sock');
  await until(()=>fs.existsSync(socketPath));transport=require('node:net').connect(socketPath);await new Promise(r=>transport.once('connect',r));receive(transport);send=v=>transport.write(JSON.stringify(v)+'\n');send({type:'open',sessionID:id});
 }else{receive(child.stdout);send({type:'connect',config});}
 await until(()=>output.includes('TP_USER> '));await until(()=>frames.some(f=>f.type==='cwd'));
 let next=1;
 async function open(elevated){const offset=frames.length;send({type:'sftpOpen',config:{execOnly:true,sourceSessionID:id,usesSudo:elevated,elevationMethod:'sudo',elevationPassword:'fixture-password'}});await until(()=>frames.slice(offset).some(f=>f.type==='sftpReady'));}
 async function cwd(){const requestID=next++;send({type:'sftpRequest',channel:'files',request:{id:requestID,action:'terminalCWD',sourceSessionID:id}});await until(()=>frames.some(f=>f.type==='sftpResponse'&&f.message.id===requestID));const reply=frames.find(f=>f.type==='sftpResponse'&&f.message.id===requestID).message;if(!reply.ok)throw Error(reply.error);return reply.result.path;}
 async function shell(command,prompt){const offset=output.length;send({type:'data',data:Buffer.from(command+'\r').toString('base64')});await until(()=>prompt==='Password: '?output.slice(offset).endsWith(prompt):output.slice(offset).includes(prompt));}
 async function command(command){const token='__done_'+next+++'__';const offset=output.length;send({type:'data',data:Buffer.from(command+`; printf '\\n${token}\\n'\r`).toString('base64')});await until(()=>output.slice(offset).includes('\r\n'+token+'\r\n'));}
 async function account(user){await until(()=>frames.filter(f=>f.type==='user').at(-1)?.username===user);}
 async function probe(){
  assert.ok(nativeBroker);const client=spawn(engine,['ssh-files'],{stdio:['pipe','pipe','pipe']});probes.push(client);
  const replies=[];readline.createInterface({input:client.stdout}).on('line',line=>replies.push(JSON.parse(line)));
  client.stdin.write(JSON.stringify({connectionID:id,sourceSessionID:id,execOnly:true,persistentElevation:true,elevationMethod:'su',elevationPassword:'root-password'})+'\n');
  await until(()=>replies.some(f=>f.event==='ready'));
  const request=async payload=>{const requestID=next++;client.stdin.write(JSON.stringify({...payload,id:requestID})+'\n');await until(()=>replies.some(f=>f.id===requestID));const result=replies.find(f=>f.id===requestID);assert.equal(result.ok,true,JSON.stringify(result));return result.result;};
  return {cwd:async()=>(await request({action:'terminalCWD',sourceSessionID:id})).path, user:async()=>await request({action:'exec',command:'id -un',elevated:true,timeoutMs:10000})};
 }
 return{open,cwd,shell,command,account,probe,close:async()=>{
  for(const client of probes){client.stdin.end();await new Promise(r=>client.exitCode!==null?r():client.once('exit',r));}
  if(nativeBroker){transport?.destroy();child.kill();}else child.stdin.end();
  await new Promise(r=>child.exitCode!==null||child.signalCode!==null?r():child.once('exit',r));
  if(socketPath){fs.rmSync(socketPath,{force:true});fs.rmSync(socketPath.replace(/\.sock$/,'.lock'),{force:true});}
  fs.rmSync(directory,{recursive:true,force:true});}};
}
test('real Linux OpenSSH: sudo PTY, su, protected cwd, background jobs and separate terminals',{skip:!port,timeout:90000},async()=>{
 const a=await terminal();let b;try{
  await a.open(true);assert.equal(await a.cwd(),'/home/fixture');
  await a.account('fixture');
  await a.shell('sleep 1; sudo -k -i','password for fixture:');await a.account('fixture');
  await a.shell('fixture-password','TP_ROOT> ');await a.account('root');assert.equal(await a.cwd(),'/root');
  await a.command("cd '/root/private logs/中文'");assert.equal(await a.cwd(),'/root/private logs/中文');
  await a.open(false);await assert.rejects(a.cwd(),/permissions/);await a.open(true);
  await a.shell('su - app','TP_APP> ');await a.account('app');assert.equal(await a.cwd(),'/home/app');
  await a.command('cd /tmp');assert.equal(await a.cwd(),'/tmp');
  await a.shell('exit','TP_ROOT> ');await a.account('root');assert.equal(await a.cwd(),'/root/private logs/中文');
  b=await terminal();await b.open(true);assert.equal(await b.cwd(),'/home/fixture');assert.equal(await a.cwd(),'/root/private logs/中文');
  await a.shell('exit','TP_USER> ');await a.account('fixture');await a.command('sleep 30 & true');assert.equal(await a.cwd(),'/home/fixture');
 }finally{await a.close();await b?.close();}
});

test('native macOS broker: separate elevated tools probe locates the original terminal and reports clean root output',{skip:!port||process.platform==='win32',timeout:90000},async()=>{
 const a=await terminal(true);try{
  const tools=await a.probe();assert.equal(await tools.cwd(),'/home/fixture');
  await a.shell('sudo -k -p "Password: " -i','Password: ');await a.account('fixture');
  await a.shell('fixture-password','TP_ROOT> ');await a.account('root');
  await a.command("cd '/root/private logs/中文'");assert.equal(await tools.cwd(),'/root/private logs/中文');
  for(let n=0;n<3;n++){const result=await tools.user();assert.equal(result.stdout.trim(),'root');assert.equal(result.exitCode,0);}
  await a.shell('su - app','TP_APP> ');await a.account('app');assert.equal(await tools.cwd(),'/home/app');
  await a.shell('exit','TP_ROOT> ');await a.account('root');assert.equal(await tools.cwd(),'/root/private logs/中文');
  await a.shell('exit','TP_USER> ');await a.account('fixture');assert.equal(await tools.cwd(),'/home/fixture');
  await a.shell('su - root','Password: ');await a.account('fixture');
  await a.shell('root-password','TP_ROOT> ');await a.account('root');assert.equal(await tools.cwd(),'/root');
  await a.shell('exit','TP_USER> ');await a.account('fixture');assert.equal(await tools.cwd(),'/home/fixture');
 }finally{await a.close();}
});
