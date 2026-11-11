import {build} from '../apps/windows/node_modules/vite/dist/node/index.js';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const root=path.resolve(import.meta.dirname,'..'),output=path.resolve(process.argv[2]||'validation/windows-responsiveness/after/ui.json');
const app=process.env.TERMPILOT_UI_SOURCE||path.join(root,'apps/windows');
const dist=path.join(path.dirname(output),'ui-fixture');
await build({root:app,base:'/',build:{outDir:dist,emptyOutDir:true,rollupOptions:{input:path.join(app,'performance/index.html')}}});
const server=createServer((req,res)=>{let file=path.join(dist,req.url.split('?')[0]);if(req.url==='/')file=path.join(dist,'performance/index.html');try{res.setHeader('Content-Type',file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file))}catch{res.statusCode=404;res.end()}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.TERMPILOT_PLAYWRIGHT||'playwright');
const executablePath=process.env.TERMPILOT_BROWSER||(process.platform==='darwin'?'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome':'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe');
const browser=await chromium.launch({executablePath,headless:true,args:['--disable-background-timer-throttling','--disable-renderer-backgrounding']});
try{const page=await browser.newPage({viewport:{width:1280,height:800}});const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(`http://127.0.0.1:${server.address().port}`);await page.waitForFunction(()=>window.benchmark);const result=await page.evaluate(()=>window.benchmark.run());result.errors=errors;fs.writeFileSync(output,JSON.stringify(result,null,2));await page.screenshot({path:output.replace(/\.json$/,'.png')});console.log(output);if(errors.length)throw Error(errors.join('\n'))}finally{await browser.close();server.close()}
