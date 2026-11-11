#include <aacenc_lib.h>
#include <vector>
#include <cstdio>
#include <cmath>
int main(int argc,char**argv){HANDLE_AACENCODER h=nullptr;if(aacEncOpen(&h,0,2))return 1;
for(auto p:std::vector<std::pair<AACENC_PARAM,UINT>>{{AACENC_AOT,39},{AACENC_SAMPLERATE,48000},{AACENC_CHANNELMODE,2},{AACENC_BITRATE,128000},{AACENC_SBR_MODE,1},{AACENC_SBR_RATIO,1},{AACENC_GRANULE_LENGTH,480},{AACENC_TRANSMUX,0}}){if(aacEncoder_SetParam(h,p.first,p.second)){fprintf(stderr,"parameter %d rejected\n",p.first);return 2;}}
if(aacEncEncode(h,nullptr,nullptr,nullptr,nullptr))return 3;AACENC_InfoStruct info{};if(aacEncInfo(h,&info))return 4;
FILE*out=fopen(argv[1],"wb");fputc(info.confSize,out);fwrite(info.confBuf,1,info.confSize,out);fprintf(stderr,"ASC ");for(unsigned i=0;i<info.confSize;i++)fprintf(stderr,"%02x",info.confBuf[i]);fprintf(stderr," frame %u\n",info.frameLength);
std::vector<INT_PCM> samples(info.frameLength*2);unsigned frame=0;for(;frame<16;frame++){
for(unsigned i=0;i<info.frameLength;i++){short v=short(5000*sin((i+frame*info.frameLength)*6.283185307179586*440/48000));samples[2*i]=samples[2*i+1]=v;}
void*ib=samples.data();int iid=IN_AUDIO_DATA,isz=samples.size()*2,ies=2;AACENC_BufDesc in{1,&ib,&iid,&isz,&ies};unsigned char bytes[8192];void*ob=bytes;int oid=OUT_BITSTREAM_DATA,osz=8192,oes=1;AACENC_BufDesc buf{1,&ob,&oid,&osz,&oes};AACENC_InArgs ia{int(samples.size()),0};AACENC_OutArgs oa{};if(aacEncEncode(h,&in,&buf,&ia,&oa))return 5;if(oa.numOutBytes){unsigned n=oa.numOutBytes;unsigned char sz[]={static_cast<unsigned char>(n>>8),static_cast<unsigned char>(n)};fwrite(sz,1,2,out);fwrite(bytes,1,n,out);}}
fclose(out);aacEncClose(&h);}
