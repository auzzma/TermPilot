// SPDX-License-Identifier: MIT
// Synthetic pixels only. Runs against the exact Android adapter shipped in APK.
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stddef.h>
#include <time.h>
typedef void (*Callback)(void*,uint32_t,const uint64_t*,const uint8_t*,size_t);
extern void* tp_media_create(Callback,void*);
extern void tp_media_destroy(void*);
extern int tp_video_configure(void*,const uint8_t*,size_t);
extern int tp_video_decode(void*,const uint8_t*,size_t,uint32_t,uint32_t);
#ifdef __ANDROID__
extern int tp_video_poll(void*);
#endif
struct Result{unsigned frames,invalid;};
static unsigned be(const uint8_t*p){return (unsigned)p[0]<<24|(unsigned)p[1]<<16|(unsigned)p[2]<<8|p[3];}
static void output(void*context,uint32_t kind,const uint64_t*m,const uint8_t*data,size_t size){
 struct Result*r=context;if(kind!=1)return;r->frames++;
 if(m[0]!=0||m[2]!=96||m[3]!=64||m[6]!=48||m[7]!=32||m[4]<96||m[5]<96||size!=m[8]+m[9]||!data)r->invalid++;
}
int tp_mobile_avc_probe(const uint8_t* data,size_t size){
 if(!data||size<8||size>1048576)return 2;
 struct Result r={0};void*d=tp_media_create(output,&r);if(!d)return 4;size_t at=0;unsigned calls=0;int status=0;
 while(at+4<=size){unsigned n=be(data+at);at+=4;if(n>size-at){status=-1;break;}
 if(calls==0)status=tp_video_configure(d,data+at,n);else status=tp_video_decode(d,data+at,n,0,calls-1);at+=n;calls++;if(status<0)break;}
#ifdef __ANDROID__
 for(int i=0;status>=0&&r.frames<30&&i<250;++i){status=tp_video_poll(d);struct timespec wait={0,2000000};nanosleep(&wait,0);}
#endif
 tp_media_destroy(d);printf("AVC native: calls=%u frames=%u invalid=%u status=%d\n",calls,r.frames,r.invalid,status);
 return status<0||r.invalid||r.frames!=30||at!=size;
}

#ifdef TERMPILOT_PROBE_MAIN
int main(int argc,char**argv){if(argc!=2)return 2;FILE*f=fopen(argv[1],"rb");if(!f)return 3;uint8_t data[1048576];size_t size=fread(data,1,sizeof(data),f);fclose(f);return tp_mobile_avc_probe(data,size);}
#endif
