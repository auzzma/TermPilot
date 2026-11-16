export type VNCDesktopState = {supported:boolean;busy:boolean;blocked:boolean;width:number;height:number;message:string};
const initial=():VNCDesktopState=>({supported:false,busy:false,blocked:false,width:0,height:0,message:"远端未提供分辨率调整能力，请在远端系统设置中修改。"});
export class VNCDesktopControl {
  state=initial();
  changed=(_state:VNCDesktopState)=>{};
  send=async(_command:Record<string,unknown>)=>{};
  private requestId?:string;
  private timer?:ReturnType<typeof setTimeout>;
  private publish(){this.changed({...this.state});}
  reset(){clearTimeout(this.timer);this.requestId=undefined;this.state=initial();this.publish();}
  event(e:Record<string,any>){
    if((e.kind==="connected"||e.kind==="desktopSize")&&Number.isInteger(e.width)&&Number.isInteger(e.height)){
      this.state.width=e.width;this.state.height=e.height;
    }else if(e.kind==="vncCapabilities"){
      this.state.supported=e.canResize===true;
      if(!this.requestId)this.state.message=this.state.supported?"分辨率修改须由远端 VNC 服务确认。":"当前显示器布局暂不支持调整，请在远端系统设置中修改。";
    }else if(e.kind==="vncResizeResult"&&this.requestId&&e.requestID===this.requestId){
      if(e.pending){this.state.message="正在等待远端系统应用分辨率…";this.publish();return;}
      clearTimeout(this.timer);this.requestId=undefined;this.state.busy=false;this.state.blocked=false;
      this.state.message=e.accepted?"远端已确认修改分辨率。":({vncResizeProhibited:"远端服务不允许修改分辨率。",vncResizeResources:"远端资源不足，无法使用此分辨率。",vncResizeUnsupported:initial().message} as Record<string,string>)[e.code]??"远端拒绝了此分辨率，请尝试其他尺寸。";
    }else return;
    this.publish();
  }
  async resize(width:number,height:number){
    if(!this.state.supported||this.state.busy||this.state.blocked)return;
    const id=crypto.randomUUID();this.requestId=id;this.state.busy=true;this.state.message="正在请求修改远端分辨率…";this.publish();
    this.timer=setTimeout(()=>{if(this.requestId!==id)return;this.state.busy=false;this.state.blocked=true;this.state.message="远端未确认分辨率，请重连后重试。";this.publish();},15000);
    try{await this.send({kind:"resize",width,height,requestID:id});}
    catch{if(this.requestId!==id)return;clearTimeout(this.timer);this.requestId=undefined;this.state.busy=false;this.state.message="连接不可用，请重连后调整分辨率。";this.publish();}
  }
}
