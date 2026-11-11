// SPDX-License-Identifier: MIT
#pragma once
#include <memory>
#include <stdexcept>
// The public OS decoder handles AVC; HEVC 4:4:4 retains the existing adapter.
namespace avc {
struct Config {
  std::vector<std::vector<uint8_t>> nals;
  int width=0,height=0;
  struct Bits {
    std::vector<uint8_t> bytes; size_t at=0;
    explicit Bits(const std::vector<uint8_t>& nal) {
      unsigned zeros=0;
      for(size_t i=1;i<nal.size();++i){uint8_t b=nal[i];if(zeros>=2&&b==3){zeros=0;continue;}bytes.push_back(b);zeros=b==0?zeros+1:0;}
    }
    uint32_t get(unsigned n){if(n>32||at+n>bytes.size()*8)throw std::runtime_error("AVC SPS bounds");uint32_t v=0;while(n--){v=(v<<1)|((bytes[at/8]>>(7-at%8))&1);++at;}return v;}
    uint32_t ue(){unsigned n=0;while(!get(1)){if(++n>24)throw std::runtime_error("AVC SPS integer");}return ((1u<<n)-1)+get(n);}
    int se(){auto n=ue();return n&1?int((n+1)/2):-int(n/2);}
  };
  explicit Config(const std::vector<uint8_t>& bytes){
    for(size_t at=0;at<bytes.size();){
      if(at+4>bytes.size()||nals.size()>=32)throw std::runtime_error("AVC parameter bounds");
      size_t n=uint32_t(bytes[at])<<24|uint32_t(bytes[at+1])<<16|uint32_t(bytes[at+2])<<8|bytes[at+3];at+=4;
      if(n<2||n>bytes.size()-at)throw std::runtime_error("AVC parameter bounds");
      nals.emplace_back(bytes.begin()+at,bytes.begin()+at+n);at+=n;
    }
    bool pps=false;
    for(const auto& nal:nals){
      if((nal[0]&31)==8){pps=true;continue;}if((nal[0]&31)!=7)throw std::runtime_error("AVC parameter type");
      Bits b(nal);auto profile=b.get(8);b.get(16);b.ue();
      if(profile==100||profile==110||profile==122||profile==244||profile==44||profile==83||profile==86||profile==118||profile==128||profile==138||profile==139||profile==134||profile==135){
        if(b.ue()!=1||b.ue()!=0||b.ue()!=0)throw std::runtime_error("AVC requires 8-bit 4:2:0");
        b.get(1);if(b.get(1)){for(int i=0;i<8;++i)if(b.get(1)){int last=8,next=8;for(int j=0;j<(i<6?16:64);++j){if(next)next=(last+b.se()+256)%256;last=next?next:last;}}}
      }
      b.ue();auto order=b.ue();if(order==0)b.ue();else if(order==1){b.get(1);b.se();b.se();auto count=b.ue();if(count>256)throw std::runtime_error("AVC SPS cycle");while(count--)b.se();}else if(order>2)throw std::runtime_error("AVC SPS order");
      b.ue();b.get(1);auto w=b.ue()+1,h=b.ue()+1;auto progressive=b.get(1);if(!progressive)b.get(1);b.get(1);
      uint32_t l=0,r=0,t=0,bot=0;if(b.get(1)){l=b.ue();r=b.ue();t=b.ue();bot=b.ue();}
      if(w>256||h>136)throw std::runtime_error("AVC dimension limit");
      width=int(w*16)-int((l+r)*2);height=int((2-progressive)*h*16)-int((t+bot)*2*(2-progressive));
      if(width<=0||height<=0||width>4096||height>2160||width%2||height%2)throw std::runtime_error("AVC dimension limit");
    }
    if(!pps||!width||!height)throw std::runtime_error("Missing AVC SPS/PPS");
  }
  std::vector<uint8_t> annex()const{std::vector<uint8_t> out;for(const auto& n:nals){out.insert(out.end(),{0,0,0,1});out.insert(out.end(),n.begin(),n.end());}return out;}
};
inline std::vector<uint8_t> annex(const std::vector<uint8_t>& avcc){
  std::vector<uint8_t> out;out.reserve(avcc.size());size_t count=0;
  for(size_t at=0;at<avcc.size();){
    if(at+4>avcc.size()||++count>256)throw std::runtime_error("AVC sample bounds");
    size_t n=uint32_t(avcc[at])<<24|uint32_t(avcc[at+1])<<16|uint32_t(avcc[at+2])<<8|avcc[at+3];at+=4;
    if(!n||n>avcc.size()-at)throw std::runtime_error("AVC sample bounds");
    out.insert(out.end(),{0,0,0,1});out.insert(out.end(),avcc.begin()+at,avcc.begin()+at+n);at+=n;
  }return out;
}
}
#if defined(__ANDROID__)
#include "avc_android.hpp"
#elif defined(_WIN32)
#include "avc_windows.hpp"
#else
namespace avc {struct Decoder {int configure(const Config&){return -3001;}int decode(const std::vector<uint8_t>&,uint32_t,uint32_t,std::vector<Picture>&){return -3001;}};}
#endif
