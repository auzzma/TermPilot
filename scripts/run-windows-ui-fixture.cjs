// Runs an already-built, synthetic React/Tauri fixture in installed Chrome/Edge.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const {chromium}=require(process.env.TERMPILOT_PLAYWRIGHT||'playwright-core');
(async()=>{
 const dist=path.resolve(process.argv[2]),output=path.resolve(process.argv[3]);
 const server=http.createServer((req,res)=>{const file=path.join(dist,req.url==='/'?'performance/index.html':req.url.split('?')[0]);try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file))}catch{res.statusCode=404;res.end()}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({executablePath:process.env.TERMPILOT_BROWSER||'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',headless:true,args:['--disable-background-timer-throttling','--disable-renderer-backgrounding']});
 try{const page=await browser.newPage({viewport:{width:1280,height:800}});const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.benchmark);const result=await page.evaluate(()=>window.benchmark.run());result.errors=errors;result.platform=process.platform;fs.writeFileSync(output,JSON.stringify(result,null,2));await page.screenshot({path:output.replace(/\.json$/,'.png')});console.log(output);if(errors.length)throw Error(errors.join('\n'))}finally{await browser.close();server.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
