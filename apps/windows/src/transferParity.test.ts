import { describe, expect, it } from "vitest";
import { TransferQueue } from "./transferQueue";
import { ScreenScroll } from "./screenScroll";
import { inTransferFilter } from "./components/FileTransferActivity";
import type { TransferRecord } from "./components/SftpPanel";

describe("Windows transfer queue and remote input",()=>{
  it("cancels queued transfers before they acquire a slot and applies the latest concurrency limit",async()=>{
    const queue=new TransferQueue(), signal=new AbortController().signal;
    const a=await queue.acquire(signal);
    const cancelled=new AbortController(), b=queue.acquire(cancelled.signal), c=queue.acquire(signal);
    cancelled.abort();expect(await b).toBeUndefined();
    queue.setLimit(2);const release=await c;
    queue.setLimit(1);
    let started=false;
    const next=queue.acquire(signal).then(done=>{started=true;return done;});
    a!();await Promise.resolve();expect(started).toBe(false);
    release!();(await next)!();expect(started).toBe(true);
  });
  it("lists failures in both completed and attention; unresolved conflicts stay active",()=>{
    const record=(state:TransferRecord["state"])=>({state}) as TransferRecord;
    for(const state of ["completed","cancelled","failed"] as const) expect(inTransferFilter(record(state),"Completed")).toBe(true);
    expect(inTransferFilter(record("failed"),"Needs attention")).toBe(true);
    expect(inTransferFilter(record("conflict"),"Completed")).toBe(false);
    expect(inTransferFilter(record("waiting"),"Queued")).toBe(true);
  });
  it("accumulates fractional pixels, splits wheel pulses, and resets direction or idle gestures",()=>{
    const scroll=new ScreenScroll();
    expect(scroll.consume(.4,0,1,300)).toEqual([]);expect(scroll.consume(.7,0,2,300)).toEqual([1]);
    expect(scroll.consume(27,0,3,300)).toEqual([10,10,7]);
    expect(scroll.consume(-.6,0,4,300)).toEqual([]);expect(scroll.consume(-.6,0,405,300)).toEqual([]);
    expect(scroll.consume(-2,1,406,300)).toEqual([-10,-10]);
    scroll.reset();expect(scroll.consume(.1,0,407,300)).toEqual([]);
  });
});
