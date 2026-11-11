/** Binary worker packets; retain all updated tiles in a single presentation. */
export function screenPackets(bytes:ArrayBuffer) {
  const packets:{header:Record<string,any>;data:Uint8Array}[]=[];
  for(let offset=0;offset<bytes.byteLength;) {
    if(bytes.byteLength-offset<4)throw Error("Truncated screen packet");
    const n=new DataView(bytes,offset).getUint32(0);offset+=4;
    if(n<2||n>65536||n>bytes.byteLength-offset)throw Error("Invalid screen header");
    const header=JSON.parse(new TextDecoder().decode(new Uint8Array(bytes,offset,n)));offset+=n;
    const length=header.payloadLength;
    if(!Number.isInteger(length)||length<0||length>64*1024*1024||length>bytes.byteLength-offset)throw Error("Invalid screen payload");
    packets.push({header,data:new Uint8Array(bytes,offset,length)});offset+=length;
    if(packets.length>16)throw Error("Too many screen tiles");
  }return packets;
}
/** Packed bi-planar 4:4:4 tiles or a single 4:2:0 AVC picture. */
export type ScreenDisplay = {width:number;height:number;tiles:number};
export function validateScreenDisplay(display:ScreenDisplay) {
  if(![[1280,720],[1920,1080],[2560,1440],[3840,2160]].some(([w,h])=>display.width===w&&display.height===h)
    ||!Number.isInteger(display.tiles)||display.tiles<1||display.tiles>4)throw Error("Invalid remote display");
}
export function validateNV24(h:Record<string,any>,data:Uint8Array,display:ScreenDisplay={width:1920,height:1080,tiles:4}) {
  validateScreenDisplay(display);
  const {tile,width:w,height}=h;
  const cw=h.chromaWidth ?? w, ch=h.chromaHeight ?? height;
  const single420=tile===0 && cw===w/2 && ch===height/2 && height>=display.height && height<=Math.ceil(display.height/16)*16;
  const tiled444=cw===w && ch===height && tile<display.tiles && height>=Math.ceil(display.height/display.tiles)
    && height<=Math.ceil(display.height/display.tiles/16)*16;
  if(![tile,w,height,cw,ch].every(Number.isInteger)||tile<0||w!==display.width||height<=0||tile*height>=display.height||(!single420&&!tiled444)||h.yStride!==w||h.uvStride!==cw*2||h.yLength!==w*height||h.uLength!==cw*ch*2||data.length!==h.yLength+h.uLength)throw Error("Invalid video picture");
}
export class HighPerformanceRenderer {
  private gl:WebGL2RenderingContext;private textures:WebGLTexture[]=[];private program:WebGLProgram;private format="";
  constructor(private canvas:HTMLCanvasElement,private display:ScreenDisplay={width:1920,height:1080,tiles:4}) {
    validateScreenDisplay(display);
    const gl=canvas.getContext("webgl2",{alpha:false,antialias:false,preserveDrawingBuffer:true});if(!gl)throw Error("需要 WebGL2 图形加速，请检查 Windows 显卡驱动");this.gl=gl;canvas.width=display.width;canvas.height=display.height;
    const shader=(type:number,source:string)=>{const s=gl.createShader(type)!;gl.shaderSource(s,source);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error("Screen shader compilation failed");return s;};
    const vs=shader(gl.VERTEX_SHADER,`#version 300 es
      out vec2 uv;uniform float extent;void main(){vec2 p=vec2(float((gl_VertexID>>1)&1),float(gl_VertexID&1));uv=vec2(p.x,(1.-p.y)*extent);gl_Position=vec4(p*2.-1.,0.,1.);}`);
    const fs=shader(gl.FRAGMENT_SHADER,`#version 300 es
      precision highp float;in vec2 uv;uniform sampler2D y;uniform sampler2D c;out vec4 color;void main(){float l=texture(y,uv).r;vec2 d=texture(c,uv).rg-vec2(128./255.);color=vec4(clamp(vec3(l+1.5748*d.y,l-.187324*d.x-.468124*d.y,l+1.8556*d.x),0.,1.),1.);}`);
    this.program=gl.createProgram()!;gl.attachShader(this.program,vs);gl.attachShader(this.program,fs);gl.linkProgram(this.program);gl.deleteShader(vs);gl.deleteShader(fs);if(!gl.getProgramParameter(this.program,gl.LINK_STATUS))throw Error("Screen shader link failed");gl.useProgram(this.program);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT,1);
    for(let i=0;i<2;i++){const texture=gl.createTexture()!;this.textures.push(texture);gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,texture);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);gl.uniform1i(gl.getUniformLocation(this.program,i?"c":"y"),i);}
  }
  update(h:Record<string,any>,data:Uint8Array){
    validateNV24(h,data,this.display);const gl=this.gl;
    const cw=h.chromaWidth??h.width,ch=h.chromaHeight??h.height;
    const single420=cw!==h.width,totalHeight=h.height*(single420?1:this.display.tiles);
    const format=`${cw}/${totalHeight}`;
    gl.useProgram(this.program);gl.uniform1f(gl.getUniformLocation(this.program,"extent"),this.display.height/totalHeight);
    for(let i=0;i<2;i++){
      gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,this.textures[i]);
      const w=i?cw:h.width, rows=i?ch:h.height;
      if(this.format!==format){const fullRows=i&&single420?totalHeight/2:totalHeight;gl.texImage2D(gl.TEXTURE_2D,0,i?gl.RG8:gl.R8,w,fullRows,0,i?gl.RG:gl.RED,gl.UNSIGNED_BYTE,new Uint8Array(w*fullRows*(i+1)).fill(i?128:0));}
      gl.texSubImage2D(gl.TEXTURE_2D,0,0,h.tile*rows,w,rows,i?gl.RG:gl.RED,gl.UNSIGNED_BYTE,i?data.subarray(h.yLength):data.subarray(0,h.yLength));
    }
    this.format=format;
  }
  description(){const gl=this.gl;return `${gl.getParameter(gl.VENDOR)} / ${gl.getParameter(gl.RENDERER)} / ${gl.getParameter(gl.VERSION)}`;}
  present(){const gl=this.gl;if(gl.isContextLost())throw Error("WebGL context lost");gl.viewport(0,0,this.canvas.width,this.canvas.height);gl.useProgram(this.program);gl.drawArrays(gl.TRIANGLE_STRIP,0,4);}
  close(){this.textures.forEach(t=>this.gl.deleteTexture(t));this.gl.deleteProgram(this.program);}
}
export class ScreenAudio {
  private context?:AudioContext;private next=0;
  resume(){this.context??=new AudioContext({sampleRate:48000});void this.context.resume();}
  push(bytes:ArrayBuffer){const c=this.context;if(!c||c.state!=="running"||!bytes.byteLength)return;if(bytes.byteLength%8||bytes.byteLength>400000)throw Error("Invalid screen audio");const samples=new Float32Array(bytes);const frames=samples.length/2;const buffer=c.createBuffer(2,frames,48000);for(let channel=0;channel<2;channel++){const dest=buffer.getChannelData(channel);for(let i=0;i<frames;i++)dest[i]=samples[i*2+channel];}if(this.next<c.currentTime||this.next>c.currentTime+.25)this.next=c.currentTime+.025;const source=c.createBufferSource();source.buffer=buffer;source.connect(c.destination);source.start(this.next);this.next+=frames/48000;}
  close(){void this.context?.close();this.context=undefined;this.next=0;}
}
