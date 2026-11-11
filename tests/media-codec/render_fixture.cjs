// Synthetic WebGL acceptance for both negotiated chroma layouts.
const fs=require('node:fs');
const ts=require('../../apps/windows/node_modules/typescript');
const source=fs.readFileSync('apps/windows/src/screenMedia.ts','utf8').replace(/^export /gm,'');
const js=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.None}}).outputText;
const verify=`
try {
 const canvas=document.querySelector('canvas'), results=[];
 for(const [width,height] of [[1280,720],[1920,1080],[2560,1440],[3840,2160]]) {
  const renderer=new HighPerformanceRenderer(canvas,{width,height,tiles:4});
  const gl=canvas.getContext('webgl2');
  const tileHeight=Math.ceil(height/4/16)*16;
  const tile=(index,value)=>{
   const data=new Uint8Array(width*tileHeight*3).fill(128);data.fill(value,0,width*tileHeight);
   renderer.update({tile:index,width,height:tileHeight,yStride:width,uvStride:width*2,yLength:width*tileHeight,uLength:width*tileHeight*2},data);
  };
  const check=(values,bandHeight)=>{
   if(canvas.width!==width||canvas.height!==height)throw Error('Canvas dimensions');
   const points=values.map((v,i)=>[width-1,height-1-(i*bandHeight+Math.floor(bandHeight/2)),v]);
   points.push([0,height-1,values[0]],[width-1,0,values[3]]);
   for(const [x,y,value] of points){const p=new Uint8Array(4);gl.readPixels(x,y,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);if(p.slice(0,3).some(n=>Math.abs(n-value)>2)||p[3]!==255)throw Error('Pixel mismatch at '+[width,height,x,y]+': '+p+' expected '+value);}
   if(gl.getError())throw Error('WebGL error');
  };
  [40,90,140,190].forEach((v,i)=>tile(i,v));renderer.present();check([40,90,140,190],tileHeight);
  for(const rows of new Set([height,Math.ceil(height/16)*16])){
   const avc=new Uint8Array(width*rows*3/2).fill(128);
   avc.fill(255,0,width*rows);
   [50,100,150,200].forEach((v,i)=>avc.fill(v,i*(height/4)*width,(i+1)*(height/4)*width));
   renderer.update({tile:0,width,height:rows,chromaWidth:width/2,chromaHeight:rows/2,yStride:width,uvStride:width,yLength:width*rows,uLength:width*rows/2},avc);renderer.present();check([50,100,150,200],height/4);
  }
  [60,110,160,210].forEach((v,i)=>tile(i,v));renderer.present();check([60,110,160,210],tileHeight);
  renderer.close();results.push({width,height,ok:true});
 }
 document.querySelector('pre').textContent=JSON.stringify({ok:true,renderer:'WebGL2',tests:['all four resolutions','HEVC tiles and padding','AVC NV12 and padding','codec switches','corner pixels and orientation'],results});
} catch(error){document.querySelector('pre').textContent=JSON.stringify({ok:false,error:String(error)});}
`;
fs.writeFileSync(process.argv[2],'<!doctype html><html><meta charset="utf-8"><title>TermPilot renderer fixture</title><canvas></canvas><pre>pending</pre><script>'+js+verify+'</script></html>');
