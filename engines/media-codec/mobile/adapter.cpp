// SPDX-License-Identifier: MIT
// The exact desktop decoder, hosted in-process on Android. No subprocess or JNI callbacks.
#include "../decoder.hpp"
#include <memory>
using Callback = void (*)(void*, uint32_t, const uint64_t*, const uint8_t*, size_t);
struct MobileDecoder {
  Decoder decoder;
  Callback callback;
  void* context;
  void diagnostic() {
#if defined(__ANDROID__)
    if(auto* avc=decoder.avc_video.get()){
      uint64_t m[10]={avc->submitted,avc->produced,uint64_t(avc->color)};
      callback(context,3,m,reinterpret_cast<const uint8_t*>(avc->name.data()),avc->name.size());
    }
#endif
  }
  void emit(const std::vector<Picture>& pictures) {
    for (const auto& p : pictures) {
      uint64_t m[10] = {p.tile,p.tag,p.width,p.height,p.width,p.width*2u,p.width,p.height,
                       uint64_t(p.width)*p.height,uint64_t(p.width)*p.height*2};
      if(p.kind==3){m[5]=p.width;m[6]=p.width/2;m[7]=p.height/2;m[9]=uint64_t(p.width)*p.height/2;}
      callback(context,p.kind==3?1:p.kind,m,p.bytes.data(),p.bytes.size());
    }
  }
};
extern "C" {
void* tp_media_create(Callback callback, void* context) noexcept {
  if (!callback || !context) return nullptr;
  try {
    auto d=std::make_unique<MobileDecoder>();d->callback=callback;d->context=context;
    std::vector<uint8_t> asc{0xf8,0xe6,0x51,0x32,0xe0,0};
    if(d->decoder.configure_audio(asc)<0)return nullptr;
    return d.release();
  } catch (...) { return nullptr; }
}
void tp_media_destroy(void* handle) noexcept { delete static_cast<MobileDecoder*>(handle); }
int tp_video_configure(void* handle,const uint8_t* data,size_t length) noexcept {
  if(!handle||!data||length>65536)return -2;
  try {auto d=static_cast<MobileDecoder*>(handle);int status=d->decoder.configure_video({data,data+length});d->diagnostic();return status;}catch(...){return -1;}
}
int tp_video_decode(void* handle,const uint8_t* data,size_t length,uint32_t tile,uint32_t tag) noexcept {
  if(!handle||!data||length>16*1024*1024)return -2;
  try {auto d=static_cast<MobileDecoder*>(handle);std::vector<Picture> pictures;int r=d->decoder.video_packet({data,data+length},tile,tag,pictures);d->emit(pictures);d->diagnostic();return r<0?r:int(pictures.size());}catch(...){return -1;}
}
#if defined(__ANDROID__)
// Nonblocking drain. Called on the same worker as configure/decode, including
// idle intervals; no detached decoder threads or cross-thread callback lifetime.
int tp_video_poll(void* handle) noexcept {
  if(!handle)return -2;
  try {
    auto d=static_cast<MobileDecoder*>(handle);auto* avc=d->decoder.avc_video.get();if(!avc)return 0;
    std::vector<Picture> pictures;int status=avc->output(pictures,0);
    d->emit(pictures);if(!pictures.empty()||status<0)d->diagnostic();
    return status<0?status:int(pictures.size());
  }catch(...){return -1;}
}
#endif
int tp_audio_configure(void* handle,const uint8_t* data,size_t length) noexcept {
  if(!handle||!data||!length||length>64)return -2;
  try {std::vector<uint8_t> bytes{data,data+length};return static_cast<MobileDecoder*>(handle)->decoder.configure_audio(bytes);}catch(...){return -1;}
}
int tp_audio_decode(void* handle,const uint8_t* data,size_t length) noexcept {
  if(!handle||!data||length>65536)return -2;
  try {auto d=static_cast<MobileDecoder*>(handle);std::vector<Picture> pictures;std::vector<uint8_t> bytes{data,data+length};int r=d->decoder.audio_packet(bytes,pictures);d->emit(pictures);return r;}catch(...){return -1;}
}
}
