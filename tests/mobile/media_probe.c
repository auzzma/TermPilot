// SPDX-License-Identifier: MIT
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
typedef void (*Callback)(void*,uint32_t,const uint64_t*,const uint8_t*,size_t);
extern void* tp_media_create(Callback,void*);
extern void tp_media_destroy(void*);
extern int tp_video_configure(void*,const uint8_t*,size_t);
extern int tp_video_decode(void*,const uint8_t*,size_t,uint32_t,uint32_t);
extern int tp_audio_configure(void*,const uint8_t*,size_t);
extern int tp_audio_decode(void*,const uint8_t*,size_t);
struct Result { unsigned tiles; size_t audio; int failed; float peak; };
static void receive(void* opaque,uint32_t kind,const uint64_t* m,const uint8_t* data,size_t size) {
  struct Result* r=(struct Result*)opaque;
  if(kind==1){if(m[0]>=4||m[2]!=64||m[3]!=64||size!=12288){r->failed=1;return;}r->tiles|=1u<<m[0];}
  if(kind==2){if(!size||size%8||size>3840){r->failed=2;return;}for(size_t i=0;i<size;i+=4){float f;memcpy(&f,data+i,4);if(!isfinite(f)||fabsf(f)>1)r->failed=3;if(fabsf(f)>r->peak)r->peak=fabsf(f);}r->audio+=size/8;}
}
int tp_mobile_media_probe(const uint8_t* audio,size_t length) {
  if(!audio||length<8)return -1;
  struct Result r={0};void* d=tp_media_create(receive,&r);if(!d)return -2;
  // Use the identical synthetic HEVC 4:4:4 fixture as desktop codec tests.
  const char* hex[]={"40010c01ffff0408000003009e280000030000baba0240","4201010408000003009e280000030000ba90041020b2dd25261734040000030004003d090020","4401c07030601120","2801ade0d117ffd39173238b80"};
  uint8_t config[256];size_t count=0;uint8_t frame[64];size_t frame_size=0;
  for(int n=0;n<4;n++){size_t len=strlen(hex[n])/2;uint8_t bytes[128];for(size_t i=0;i<len;i++){unsigned x;sscanf(hex[n]+i*2,"%2x",&x);bytes[i]=(uint8_t)x;}if(n<3){config[count++]=0;config[count++]=0;config[count++]=0;config[count++]=(uint8_t)len;memcpy(config+count,bytes,len);count+=len;}else{memcpy(frame,bytes,len);frame_size=len;}}
  int result=tp_video_configure(d,config,count);
  if(result!=0){tp_media_destroy(d);return result;}
  for(uint32_t tile=0;tile<4;tile++){if(tp_video_decode(d,frame,frame_size,tile,tile+123)<0)r.failed=4;}
  if ((size_t)audio[0]+1>length || tp_audio_configure(d,audio+1,audio[0])<0) {tp_media_destroy(d);return -7;}
  size_t at=1+audio[0], packets=0;
  while(at+2<=length){size_t size=((size_t)audio[at]<<8)|audio[at+1];at+=2;if(at+size>length){r.failed=5;break;}if(tp_audio_decode(d,audio+at,size)<0)r.failed=6;at+=size;packets++;}
  tp_media_destroy(d);
  fprintf(stderr,"Media probe: tiles=%u audio_frames=%zu packets=%zu peak=%f error=%d\n",r.tiles,r.audio,packets,r.peak,r.failed);
  if(at!=length||r.tiles!=15||r.audio>packets*480||r.audio+960<packets*480||r.peak<.05f||r.failed)return -100-r.failed;
  return 0;
}
#ifdef TERMPILOT_PROBE_MAIN
struct RecoveryResult { unsigned frames, last_tag, errors; int invalid; };
static void recovered(void* opaque,uint32_t kind,const uint64_t* m,const uint8_t* data,size_t size) {
  struct RecoveryResult* r=(struct RecoveryResult*)opaque;
  if(kind!=1||m[2]!=96||m[3]!=64||size!=96*64*3||m[0]!=m[1]%4||!data){r->invalid=1;return;}
  r->frames++;r->last_tag=(unsigned)m[1];
}
static unsigned be32(const uint8_t* p){return (unsigned)p[0]<<24|(unsigned)p[1]<<16|(unsigned)p[2]<<8|p[3];}
static int recovery_probe(const char* path) {
  FILE* f=fopen(path,"rb");if(!f)return 3;
  uint8_t* bytes=malloc(1024*1024);if(!bytes){fclose(f);return 4;}
  size_t length=fread(bytes,1,1024*1024,f);int overflow=fgetc(f)!=EOF;fclose(f);
  if(overflow){free(bytes);return 5;}
  uint8_t config[65536];size_t count=0,at=0;
  while(at+4<=length){unsigned n=be32(bytes+at);if(n<2||n>length-at-4){free(bytes);return 6;}
    unsigned kind=(bytes[at+4]>>1)&63;if(kind<32)break;
    if(kind>=32&&kind<=34){if(count+n+4>sizeof(config)){free(bytes);return 7;}memcpy(config+count,bytes+at,n+4);count+=n+4;}at+=n+4;
  }
  struct RecoveryResult r={0};void* d=tp_media_create(recovered,&r);if(!d){free(bytes);return 8;}
  int status=tp_video_configure(d,config,count);unsigned tag=0;
  while(status==0&&at+4<=length){unsigned n=be32(bytes+at);at+=4;if(n<2||n>length-at){status=-1;break;}
    if(((bytes[at]>>1)&63)<32){
      if(tag!=8&&tag!=98){int s=tp_video_decode(d,bytes+at,n,tag%4,tag);if(s<0){r.errors++;if(s!=-1009){status=s;break;}}}tag++;
    }at+=n;
  }
  tp_media_destroy(d);free(bytes);
  printf("Native HEVC loss recovery: input=%u frames=%u last=%u errors=%u invalid=%d status=%d\n",tag,r.frames,r.last_tag,r.errors,r.invalid,status);
  return status||at!=length||tag!=200||r.frames!=36||r.last_tag!=199||r.errors!=2||r.invalid;
}
int main(int argc,char**argv){if(argc!=3)return 2;FILE* f=fopen(argv[1],"rb");if(!f)return 3;uint8_t bytes[65536];size_t n=fread(bytes,1,sizeof(bytes),f);fclose(f);int r=tp_mobile_media_probe(bytes,n);printf("HEVC444 four tiles / AAC-ELD-SBR PCM: %d\n",r);return r?1:recovery_probe(argv[2]);}
#endif
