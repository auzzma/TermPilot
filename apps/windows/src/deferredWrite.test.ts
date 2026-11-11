import {afterEach,describe,expect,it,vi} from 'vitest';
import {DeferredWrite} from './deferredWrite';
import {frameCoalescer,refreshInterval,latestAsync} from './uiScheduling';
afterEach(()=>{vi.useRealTimers();vi.unstubAllGlobals()});
describe('durable coalesced persistence',()=>{
 it('coalesces a burst, and flush saves immediately before close',async()=>{
  vi.useFakeTimers();const write=vi.fn().mockResolvedValue(undefined),q=new DeferredWrite<number>(write,()=>{});
  for(let i=0;i<120;i++)q.enqueue(i);
  expect(write).not.toHaveBeenCalled();expect(q.dirty).toBe(true);
  await q.flush();expect(write).toHaveBeenCalledExactlyOnceWith(119);expect(q.dirty).toBe(false);
  await vi.runAllTimersAsync();expect(write).toHaveBeenCalledTimes(1);
 });
 it('never overlaps writes and the newest edit wins while an older save is running',async()=>{
  vi.useFakeTimers();let release!:()=>void;
  const write=vi.fn().mockImplementationOnce(()=>new Promise<void>(r=>release=r)).mockResolvedValue(undefined);
  const q=new DeferredWrite<number>(write,()=>{});q.enqueue(1);const flush=q.flush();
  q.enqueue(2);q.enqueue(3);expect(write).toHaveBeenCalledTimes(1);release();await flush;
  expect(write.mock.calls.map(c=>c[0])).toEqual([1,3]);expect(q.dirty).toBe(false);
 });
 it('retains failures for explicit retry without rolling back a newer value',async()=>{
  vi.useFakeTimers();let reject!:(e:Error)=>void;const report=vi.fn();
  const write=vi.fn().mockImplementationOnce(()=>new Promise((_,r)=>reject=r)).mockResolvedValue(undefined);
  const q=new DeferredWrite<number>(write,report);q.enqueue(1);const flush=q.flush();q.enqueue(2);
  reject(Error('disk busy'));await expect(flush).rejects.toThrow('disk busy');expect(q.dirty).toBe(true);
  await q.flush();expect(write.mock.calls.map(c=>c[0])).toEqual([1,2]);expect(q.dirty).toBe(false);
 });
 it('retains the failed value if there is no newer edit',async()=>{
  vi.useFakeTimers();const write=vi.fn().mockRejectedValueOnce(Error('full')).mockResolvedValue(undefined);
  const q=new DeferredWrite<number>(write,()=>{});q.enqueue(9);await expect(q.flush()).rejects.toThrow();await q.flush();expect(write.mock.calls).toEqual([[9],[9]]);
 });
 it('bounds save delay during a sustained sequence of edits',async()=>{
  vi.useFakeTimers();const write=vi.fn().mockResolvedValue(undefined);const q=new DeferredWrite<number>(write,()=>{},150,500);
  for(let i=0;i<5;i++){q.enqueue(i);await vi.advanceTimersByTimeAsync(100)}
  expect(write).toHaveBeenCalledExactlyOnceWith(4);
 });
});
describe('frame and polling scheduling',()=>{
 it('keeps the last drag position and cancels stale frames',()=>{
  let callback!:FrameRequestCallback;vi.stubGlobal('requestAnimationFrame',vi.fn(f=>{callback=f;return 1}));vi.stubGlobal('cancelAnimationFrame',vi.fn());
  const apply=vi.fn(),q=frameCoalescer<number>(apply);for(let i=0;i<120;i++)q.schedule(i);
  expect(requestAnimationFrame).toHaveBeenCalledTimes(1);q.flush();expect(apply).toHaveBeenCalledExactlyOnceWith(119);callback(0);expect(apply).toHaveBeenCalledTimes(1);
  q.schedule(999);q.cancel();callback(0);expect(apply).toHaveBeenCalledTimes(1);
 });
 it('does not flood the command bridge when old settings omit intervals',()=>{
  expect(refreshInterval(NaN)).toBe(5000);expect(refreshInterval(undefined as unknown as number)).toBe(5000);
  expect(refreshInterval(0)).toBe(1000);expect(refreshInterval(100)).toBe(10000);
 });
});

 it('serializes slow resize requests and discards obsolete sizes and disposed work',async()=>{
  let release!:()=>void;
  const apply=vi.fn().mockImplementationOnce(()=>new Promise<void>(r=>release=r)).mockResolvedValue(undefined);
  const q=latestAsync<number>(apply,()=>{});q.submit(1);q.submit(2);q.submit(3);
  expect(apply.mock.calls).toEqual([[1]]);release();await new Promise(r=>setTimeout(r,0));
  expect(apply.mock.calls).toEqual([[1],[3]]);q.dispose();q.submit(4);expect(apply.mock.calls).toEqual([[1],[3]]);
 });
