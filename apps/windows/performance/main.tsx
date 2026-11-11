// Development-only fixture. This entry is never included in the application build.
import React from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {mockIPC,mockWindows} from '@tauri-apps/api/mocks';
import {App} from '../src/App';
import {SystemPanel} from '../src/components/SystemPanel';
import {TmuxPanel} from '../src/components/TmuxPanel';
import {useAppStore} from '../src/store';
import '../src/styles.css';
import '../src/windows-shell.css';
const calls: Record<string,number> = {};
const snapshot = {...useAppStore.getState(),platform:'windows', preferences:{...useAppStore.getState().preferences,language:'en',autoOpenSystemOverview:false,theme:'dark'}};
mockIPC((command,args:any)=>{
 calls[command]=(calls[command]||0)+1;
 if(command==='bootstrap')return snapshot;
 if(command==='sync_request')return args.request.method==='sync.tick'?{skipped:true}:{};
 if(command==='available_terminal_fonts')return ['Consolas','Courier New'];
 if(command==='local_exec')return {stdout:'',stderr:'',code:0};
 if(command==='local_list')return {entries:[]};
 if(command==='local_home')return 'C:\\fixture';
 if(command==='autocomplete_suggestions')return [];
 return undefined;
},{shouldMockEvents:true});
mockWindows('main');
const sleep=(ms:number)=>new Promise(r=>setTimeout(r,ms));
const frame=()=>new Promise(r=>requestAnimationFrame(r));
createRoot(document.getElementById('root')!).render(<App/>);
async function ready(){while(useAppStore.getState().loading)await sleep(10);await frame();await frame()}
function workspace(n:number){
 const sessions=Array.from({length:n},(_,i)=>({id:`s${i}`,title:`Terminal ${i+1}`,kind:'local' as const,lifecycle:'connected' as const,shell:'powershell.exe',fontSize:13}));
 useAppStore.setState({navigation:'hosts',workspace:{version:1,savedAt:new Date().toISOString(),activeWorkspaceId:'w',sessions,workspaces:[{id:'w',title:'Fixture',pinned:false,focusedSessionId:'s0',root:{type:'tabGroup',id:'tabs',sessionIds:sessions.map(s=>s.id),activeSessionId:'s0'}}]}});
}
function click(text:string){const b=[...document.querySelectorAll('button')].find(b=>b.textContent?.trim()===text);if(!b)throw Error('Missing '+text);b.click()}
async function measure(action:(i:number)=>void){const samples=[];for(let i=0;i<25;i++){await frame();const start=performance.now();flushSync(()=>action(i));document.body.getBoundingClientRect(); // Includes synchronous React commit and forced layout, excludes display scanout.
 const duration=performance.now()-start;if(i>=5)samples.push(duration);await frame()}
 const sorted=[...samples].sort((a,b)=>a-b);return {medianMS:sorted[10],p95MS:sorted[18],samples};}
(window as any).benchmark={calls, async run(){await ready();const result:any={method:'Production React commit + forced layout; mock Tauri IPC, no disk/network, 5 warmup + 20 samples',userAgent:navigator.userAgent,cases:[]};
 for(const n of [1,5,10]){flushSync(()=>workspace(n));await sleep(300);
 const tabs=await measure(i=>useAppStore.getState().selectTab('w',`s${i%n}`));
 const settings=await measure(i=>useAppStore.getState().setNavigation(i%2?'hosts':'settings'));
 flushSync(()=>useAppStore.getState().setNavigation('settings'));
 const sections=await measure(i=>useAppStore.getState().setNavigation(i%2?'about':'settings'));
 result.cases.push({sessions:n,tabs,settings,sections});}
 flushSync(()=>useAppStore.getState().setNavigation('hosts'));await sleep(250);
 const before={...calls};for(let i=0;i<120;i++)useAppStore.getState().selectTab('w',`s${i%10}`);await sleep(1400);
 result.tabBurstCalls=Object.fromEntries(Object.entries(calls).map(([k,v])=>[k,v-(before[k]||0)]).filter(([,v])=>v));
 const divider=document.querySelector('.app-sidebar-resizer')!;divider.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:280}));
 let writes=0;const original=Storage.prototype.setItem;Storage.prototype.setItem=function(...args){writes++;original.apply(this,args)};
 for(let i=0;i<120;i++)window.dispatchEvent(new PointerEvent('pointermove',{clientX:260+i%100}));window.dispatchEvent(new PointerEvent('pointerup'));await frame();Storage.prototype.setItem=original;result.sidebarStorageWrites=writes;
 // Split dragging must leave a durable final ratio without writing each move.
 flushSync(()=>{const w=useAppStore.getState().workspace;useAppStore.setState({workspace:{...w,workspaces:[{...w.workspaces[0],root:{type:'split',id:'split',axis:'vertical',sizes:[0.5,0.5],children:[{type:'pane',id:'left',sessionId:'s0'},{type:'tabGroup',id:'right',sessionIds:w.sessions.slice(1).map(s=>s.id),activeSessionId:'s1'}]}}]}})});
 await sleep(300);const splitBefore=calls.save_workspace||0;
 const split=document.querySelector('.split-resizer')!;const bounds=split.parentElement!.parentElement!.getBoundingClientRect();
 split.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:bounds.left+bounds.width/2}));
 for(let i=0;i<120;i++)window.dispatchEvent(new PointerEvent('pointermove',{clientX:bounds.left+bounds.width*(0.4+i/1200)}));
 window.dispatchEvent(new PointerEvent('pointerup'));await sleep(1400);
 result.splitDragSaves=(calls.save_workspace||0)-splitBefore;
 result.finalSplitSizes=(useAppStore.getState().workspace.workspaces[0].root as any).sizes;
 const shell=document.querySelector<HTMLElement>('.app-shell')!;shell.style.width='1280px';await frame();await frame();
 const resizeBefore=calls.terminal_resize||0;
 for(let i=0;i<40;i++){shell.style.width=`${1280+(i%2)/4}px`;await frame();await frame()}
 result.subCellResizeCalls=(calls.terminal_resize||0)-resizeBefore;
 const prefBefore=calls.save_preferences||0;
 for(let i=0;i<120;i++)void useAppStore.getState().updatePreferences({...useAppStore.getState().preferences,terminalFontSize:12+i%4});
 await sleep(1400);result.preferenceBurstSaves=(calls.save_preferences||0)-prefBefore;
 const panelContainer=document.createElement('div');document.body.appendChild(panelContainer);const panelRoot=createRoot(panelContainer);
 useAppStore.setState({preferences:{...useAppStore.getState().preferences,overviewRefreshInterval:1,tmuxRefreshInterval:1}});
 const pollBefore=calls.local_exec||0;
 flushSync(()=>panelRoot.render(<><SystemPanel active={false} session={useAppStore.getState().workspace.sessions[0]}/><TmuxPanel active={false} session={useAppStore.getState().workspace.sessions[0]}/></>));
 await sleep(2200);result.hiddenPanelCalls=(calls.local_exec||0)-pollBefore;panelRoot.unmount();panelContainer.remove();
 result.calls=calls;return result;
}};
