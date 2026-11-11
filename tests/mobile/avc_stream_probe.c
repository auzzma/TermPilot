// SPDX-License-Identifier: MIT
// Development-only stdin decoder probe. Never writes pixels or input bitstreams.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dlfcn.h>
typedef void (*Callback)(void*,uint32_t,const uint64_t*,const uint8_t*,size_t);
extern void* tp_media_create(Callback,void*);
extern void tp_media_destroy(void*);
extern int tp_video_configure(void*,const uint8_t*,size_t);
extern int tp_video_decode(void*,const uint8_t*,size_t,uint32_t,uint32_t);
struct Result { unsigned frames,invalid,width,height; char decoder[192]; };
static void output(void*ctx,uint32_t kind,const uint64_t*m,const uint8_t*p,size_t n){
  struct Result*r=ctx;
  if(kind==3){size_t len=n<sizeof(r->decoder)-1?n:sizeof(r->decoder)-1;memcpy(r->decoder,p,len);r->decoder[len]=0;return;}
  if(kind!=1)return;
  r->frames++;r->width=m[2];r->height=m[3];
  if(!m[2]||!m[3]||m[6]*2!=m[2]||m[7]*2!=m[3]||m[8]+m[9]!=n||!p)r->invalid++;
}
static uint64_t clock_us(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000+t.tv_nsec/1000;}
int main(void){
  struct Result result={0};void*d=tp_media_create(output,&result);if(!d)return 2;
  int(*poll)(void*)=dlsym(RTLD_DEFAULT,"tp_video_poll");uint32_t h[4];
  while(fread(h,sizeof(h),1,stdin)==1){
    if(h[3]>16*1024*1024)return 3;
    uint8_t*p=malloc(h[3]?h[3]:1);if(!p)return 4;
    if(h[3]&&fread(p,1,h[3],stdin)!=h[3])return 5;
    uint64_t start=clock_us();int status=-1;
    if(h[0]==1)status=tp_video_configure(d,p,h[3]);
    if(h[0]==2)status=tp_video_decode(d,p,h[3],h[1],h[2]);
    if(h[0]==3)status=poll?poll(d):0;
    free(p);
    printf("{\"status\":%d,\"frames\":%u,\"invalid\":%u,\"width\":%u,\"height\":%u,\"micros\":%llu,\"decoder\":\"%s\"}\n",status,result.frames,result.invalid,result.width,result.height,(unsigned long long)(clock_us()-start),result.decoder);fflush(stdout);
  }
  tp_media_destroy(d);return 0;
}
