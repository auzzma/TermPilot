import {describe,it,expect} from "vitest";
import {screenPackets,validateNV24,validateScreenDisplay,RawScreenRenderer,rawFrameGeometry} from "./screenMedia";
function packet(tile:number){const body=new Uint8Array(1920*272*3);const h={kind:"frame",tile,width:1920,height:272,yStride:1920,uvStride:3840,yLength:1920*272,uLength:1920*272*2,payloadLength:body.length};const header=new TextEncoder().encode(JSON.stringify(h));const bytes=new Uint8Array(4+header.length+body.length);new DataView(bytes.buffer).setUint32(0,header.length);bytes.set(header,4);return bytes;}
describe('Apple high-performance tiled presentation',()=>{
 it.each([[1280,720],[1920,1080],[2560,1440],[3840,2160]])('validates AVC and padded HEVC at %i × %i',(width,desktopHeight)=>{
   for(const tiles of [1,4]){
     const height=Math.ceil(desktopHeight/tiles/16)*16;
     const display={width,height:desktopHeight,tiles};
     const h={tile:tiles-1,width,height,chromaWidth:width,chromaHeight:height,yStride:width,uvStride:width*2,yLength:width*height,uLength:width*height*2};
     const data=new Uint8Array(width*height*3);
     expect(()=>validateNV24(h,data,display)).not.toThrow();
     expect(()=>validateNV24({...h,tile:tiles},data,display)).toThrow();
     expect(()=>validateNV24(h,data,{...display,width:1921})).toThrow();
   }
   const height=Math.ceil(desktopHeight/16)*16;
   const h={tile:0,width,height,chromaWidth:width/2,chromaHeight:height/2,yStride:width,uvStride:width,yLength:width*height,uLength:width*height/2};
   expect(()=>validateNV24(h,new Uint8Array(width*height*3/2),{width,height:desktopHeight,tiles:1})).not.toThrow();
 });
 it('rejects invalid desktop metadata',()=>{
   for(const display of [{width:7680,height:4320,tiles:4},{width:2560,height:1080,tiles:4},{width:1920,height:1080,tiles:0}])expect(()=>validateScreenDisplay(display)).toThrow();
 });
 it('retains all four independently updated tiles in order',()=>{const packets=[0,1,2,3].map(packet);const bytes=new Uint8Array(packets.reduce((s,p)=>s+p.length,0));let offset=0;for(const p of packets){bytes.set(p,offset);offset+=p.length;}const frames=screenPackets(bytes.buffer);expect(frames.map(f=>f.header.tile)).toEqual([0,1,2,3]);for(const f of frames)expect(()=>validateNV24(f.header,f.data)).not.toThrow();});
 it('accepts full AVC 4:2:0 pictures and rejects malformed chroma',()=>{
   const data=new Uint8Array(1920*1080*3/2);const h={tile:0,width:1920,height:1080,chromaWidth:960,chromaHeight:540,yStride:1920,uvStride:1920,yLength:1920*1080,uLength:1920*540};
   expect(()=>validateNV24(h,data)).not.toThrow();expect(()=>validateNV24({...h,chromaHeight:1080},data)).toThrow();expect(()=>validateNV24({...h,tile:1},data)).toThrow();
 });
 it('rejects truncated and malformed lengths before accessing pixels',()=>{const p=packet(0);expect(()=>screenPackets(p.buffer.slice(0,-1))).toThrow();new DataView(p.buffer).setUint32(0,0xffffffff);expect(()=>screenPackets(p.buffer)).toThrow();});
 it('rejects a tile that extends beyond the desktop',()=>{const f=screenPackets(packet(4).buffer)[0];expect(()=>validateNV24(f.header,f.data)).toThrow();});
});

describe("raw VNC bands", () => {
  const header=(tile:number,generation=1,desktop=130)=>({pixelFormat:"bgrx",tile,rawGeneration:generation,
    width:2,height:Math.min(64,desktop-tile*64),yStride:8,originY:tile*64,desktopWidth:2,desktopHeight:desktop});
  it("updates only changed bands and reuses image storage without clearing the canvas", () => {
    const calls:{image:ImageData;y:number}[]=[];
    let allocations=0,resizes=0,width=0,height=0;
    const context={createImageData:(w:number,h:number)=>{allocations++;return {width:w,height:h,data:new Uint8ClampedArray(w*h*4)};},
      putImageData:(image:ImageData,_x:number,y:number)=>calls.push({image,y})};
    const canvas={getContext:()=>context,get width(){return width;},set width(v:number){width=v;resizes++;},
      get height(){return height;},set height(v:number){height=v;resizes++;}} as unknown as HTMLCanvasElement;
    const renderer=new RawScreenRenderer(canvas);
    renderer.update(header(0),new Uint8Array(512).fill(1));
    renderer.update(header(2),new Uint8Array(16).fill(2));
    renderer.update(header(0),new Uint8Array(512).fill(3));
    expect(calls.map(c=>c.y)).toEqual([0,128,0]);expect(allocations).toBe(2);expect(resizes).toBe(2);
    expect(calls[0].image).toBe(calls[2].image);expect(calls[1].image.data[0]).toBe(2);
    renderer.update(header(0,2,64),new Uint8Array(512));
    expect(renderer.update(header(2),new Uint8Array(16))).toBe(false);expect(canvas.height).toBe(64);
  });
  it("rejects misaligned bands and accepts legacy full-frame RDP", () => {
    expect(()=>rawFrameGeometry({...header(2),originY:127},16)).toThrow();
    expect(()=>rawFrameGeometry({...header(0),rawGeneration:0},512)).toThrow();
    expect(rawFrameGeometry({pixelFormat:"bgrx",width:2,height:2,yStride:8,tile:0},16).y).toBe(0);
  });
});
