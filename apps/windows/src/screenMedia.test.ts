import {describe,it,expect} from "vitest";
import {screenPackets,validateNV24,validateScreenDisplay} from "./screenMedia";
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
