// Apple screen sharing uses pixel pulses; standard VNC and RDP use wheel ticks.
export class ScreenScroll {
  private remainder = 0;
  private time = 0;
  private mode = -1;
  reset() { this.remainder=0; this.time=0; this.mode=-1; }
  consume(delta:number, mode:number, time:number, pageHeight:number) {
    if(!Number.isFinite(delta) || !Number.isFinite(time)){this.reset();return [];}
    if(mode!==this.mode || time<this.time || time-this.time>300 || delta*this.remainder<0) this.remainder=0;
    this.mode=mode;this.time=time;
    const distance=delta*(mode===1?10:mode===2?Math.max(1,pageHeight):1);
    const total=this.remainder+Math.max(-1000,Math.min(1000,distance));
    let whole=Math.trunc(total); this.remainder=total-whole;
    const pulses:number[]=[];
    while(whole!==0){const step=Math.max(-10,Math.min(10,whole));pulses.push(step);whole-=step;}
    return pulses;
  }
}
