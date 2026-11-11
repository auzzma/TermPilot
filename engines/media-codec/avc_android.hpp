// SPDX-License-Identifier: MIT
#pragma once
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <string>
namespace avc {
struct Decoder {
  AMediaCodec* codec=nullptr;
  int width=0,height=0,stride=0,slice=0,color=0,left=0,top=0;
  std::string name;
  uint64_t submitted=0,produced=0;
  ~Decoder(){if(codec){AMediaCodec_stop(codec);AMediaCodec_delete(codec);}}
  int configure(const Config& config){
    codec=AMediaCodec_createDecoderByType("video/avc");if(!codec)return -3001;
    char* codec_name=nullptr;
    if(AMediaCodec_getName(codec,&codec_name)==AMEDIA_OK&&codec_name){name=codec_name;AMediaCodec_releaseName(codec,codec_name);}
    width=config.width;height=config.height;
    auto format=AMediaFormat_new();if(!format)return -3001;
    AMediaFormat_setString(format,AMEDIAFORMAT_KEY_MIME,"video/avc");
    AMediaFormat_setInt32(format,AMEDIAFORMAT_KEY_WIDTH,width);AMediaFormat_setInt32(format,AMEDIAFORMAT_KEY_HEIGHT,height);
    // Request a documented byte-buffer YUV layout; inspect the actual output.
    AMediaFormat_setInt32(format,AMEDIAFORMAT_KEY_COLOR_FORMAT,21);
    AMediaFormat_setInt32(format,"low-latency",1);AMediaFormat_setInt32(format,"priority",0);
    // Use the documented AVC format keys, including on vendor decoders that
    // expect separate SPS and PPS buffers when configured through MediaFormat.
    std::vector<uint8_t> sps,pps;
    for(const auto& nal:config.nals){auto& data=(nal[0]&31)==7?sps:pps;data.insert(data.end(),{0,0,0,1});data.insert(data.end(),nal.begin(),nal.end());}
    AMediaFormat_setBuffer(format,"csd-0",sps.data(),sps.size());
    AMediaFormat_setBuffer(format,"csd-1",pps.data(),pps.size());
    auto result=AMediaCodec_configure(codec,format,nullptr,nullptr,0);AMediaFormat_delete(format);
    if(result!=AMEDIA_OK)return int(result);return int(AMediaCodec_start(codec));
  }
  int output(std::vector<Picture>& pictures,int64_t wait){
    for(int count=0;count<32;++count){
      if(pictures.size()>=16)return 0;
      AMediaCodecBufferInfo info{};auto index=AMediaCodec_dequeueOutputBuffer(codec,&info,wait);wait=0;
      if(index==AMEDIACODEC_INFO_TRY_AGAIN_LATER)return 0;
      if(index==AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)continue;
      if(index==AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED){
        auto f=AMediaCodec_getOutputFormat(codec);if(!f)return -3002;
        int32_t codedw=0,codedh=0,right=-1,bottom=-1;
        AMediaFormat_getInt32(f,"width",&codedw);AMediaFormat_getInt32(f,"height",&codedh);
        stride=codedw;slice=codedh;left=top=0;
        AMediaFormat_getInt32(f,"stride",&stride);AMediaFormat_getInt32(f,"slice-height",&slice);
        AMediaFormat_getInt32(f,"color-format",&color);AMediaFormat_getInt32(f,"crop-left",&left);AMediaFormat_getInt32(f,"crop-top",&top);
        AMediaFormat_getInt32(f,"crop-right",&right);AMediaFormat_getInt32(f,"crop-bottom",&bottom);AMediaFormat_delete(f);
        if(right>=left)width=right-left+1;if(bottom>=top)height=bottom-top+1;
        if(slice==0)slice=codedh;
        if(left<0||top<0||left+width>stride||top+height>slice||stride%2||slice%2||stride<width||slice<height||stride>8192||slice>4320||width<=0||height<=0||width>4096||height>2160||width%2||height%2||left%2||top%2||(color!=19&&color!=21))return -3003;
        continue;
      }
      if(index<0)return int(index);
      int result=0;
      if(info.size>0){
        size_t capacity=0;auto p=AMediaCodec_getOutputBuffer(codec,index,&capacity);
        size_t ysize=size_t(stride)*slice,needed=ysize+ysize/2;
        if(!p||info.offset<0||size_t(info.offset)>capacity||needed>capacity-size_t(info.offset)||pictures.size()>=16||stride<=0||slice<=0){result=-3004;}
        else {
          p+=info.offset;Picture picture{3,0,uint32_t(info.presentationTimeUs),uint32_t(width),uint32_t(height),{}};
          picture.bytes.resize(size_t(width)*height*3/2);auto dst=picture.bytes.data();
          for(int row=0;row<height;++row)memcpy(dst+size_t(row)*width,p+size_t(row+top)*stride+left,width);
          auto uv=dst+size_t(width)*height;
          for(int row=0;row<height/2;++row){
            if(color==21)memcpy(uv+size_t(row)*width,p+ysize+size_t(row+top/2)*stride+left,width);
            else for(int col=0;col<width/2;++col){auto at=size_t(row+top/2)*(stride/2)+col+left/2;uv[size_t(row)*width+col*2]=p[ysize+at];uv[size_t(row)*width+col*2+1]=p[ysize+ysize/4+at];}
          }
          pictures.push_back(std::move(picture));++produced;
        }
      }
      AMediaCodec_releaseOutputBuffer(codec,index,false);
      if(result)return result;
    }return -3005;
  }
  int decode(const std::vector<uint8_t>& avcc,uint32_t tile,uint32_t tag,std::vector<Picture>& pictures){
    if(!codec||tile!=0)return -3001;
    auto data=annex(avcc);int status=output(pictures,0);if(status<0)return status;
    // Complete access-unit boundaries and monotonic microsecond timestamps.
    // The RTP-derived tag wraps at 16 bits and is not a presentation timestamp.
    data.insert(data.begin(),{0,0,0,1,9,0xf0});data.insert(data.end(),{0,0,0,1,9,0xf0});
    auto index=AMediaCodec_dequeueInputBuffer(codec,20000);if(index<0)return -3006;
    size_t capacity=0;auto bytes=AMediaCodec_getInputBuffer(codec,index,&capacity);
    if(!bytes||data.size()>capacity)return -3007;
    memcpy(bytes,data.data(),data.size());
    auto result=AMediaCodec_queueInputBuffer(codec,index,0,data.size(),int64_t(submitted)*16667,0);if(result!=AMEDIA_OK)return int(result);
    ++submitted;
    // MediaCodec is pipelined: output may require several submitted pictures.
    // Waiting 20ms after every input stalls 60fps, fills the 120ms Rust queue,
    // and repeatedly destroys a decoder before it can produce its first frame.
    // The owning Rust worker also polls while idle so the final frame arrives
    // without another network packet. All codec calls stay on that worker.
    return output(pictures,0);
  }
};
}
