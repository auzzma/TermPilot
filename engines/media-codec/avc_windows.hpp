// SPDX-License-Identifier: MIT
#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <codecapi.h>
#include <wrl/client.h>
#include <chrono>
namespace avc {
using Microsoft::WRL::ComPtr;
struct Decoder {
  ComPtr<IMFTransform> codec;bool com=false,mf=false;UINT32 width=0,height=0;LONG stride=0;
  std::vector<uint8_t> parameters; bool first=true;LONGLONG sequence=0;
  ~Decoder(){codec.Reset();if(mf)MFShutdown();if(com)CoUninitialize();}
  HRESULT output_type(){
    for(DWORD i=0;i<64;++i){ComPtr<IMFMediaType> type;auto hr=codec->GetOutputAvailableType(0,i,&type);if(FAILED(hr))return hr;
      GUID subtype{};type->GetGUID(MF_MT_SUBTYPE,&subtype);if(subtype!=MFVideoFormat_NV12)continue;
      hr=codec->SetOutputType(0,type.Get(),0);if(FAILED(hr))continue;
      hr=MFGetAttributeSize(type.Get(),MF_MT_FRAME_SIZE,&width,&height);if(FAILED(hr)||width==0||height==0||width>4096||height>2160||width%2||height%2)return E_INVALIDARG;
      UINT32 pitch=0;if(SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE,&pitch)))stride=LONG(pitch);else stride=LONG(width);
      return stride>=LONG(width)&&stride<=8192?S_OK:E_INVALIDARG;
    }return MF_E_INVALIDMEDIATYPE;
  }
  int configure(const Config& config){
    auto hr=CoInitializeEx(nullptr,COINIT_MULTITHREADED);com=SUCCEEDED(hr);if(FAILED(hr)&&hr!=RPC_E_CHANGED_MODE)return int(hr);
    hr=MFStartup(MF_VERSION,MFSTARTUP_LITE);if(FAILED(hr))return int(hr);mf=true;
    hr=CoCreateInstance(CLSID_CMSH264DecoderMFT,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&codec));if(FAILED(hr))return int(hr);
    ComPtr<ICodecAPI> settings;if(SUCCEEDED(codec.As(&settings))){VARIANT v;VariantInit(&v);v.vt=VT_BOOL;v.boolVal=VARIANT_TRUE;settings->SetValue(&CODECAPI_AVLowLatencyMode,&v);}
    ComPtr<IMFMediaType> type;hr=MFCreateMediaType(&type);if(FAILED(hr))return int(hr);
    type->SetGUID(MF_MT_MAJOR_TYPE,MFMediaType_Video);type->SetGUID(MF_MT_SUBTYPE,MFVideoFormat_H264);
    MFSetAttributeSize(type.Get(),MF_MT_FRAME_SIZE,config.width,config.height);MFSetAttributeRatio(type.Get(),MF_MT_FRAME_RATE,60,1);
    type->SetUINT32(MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive);
    hr=codec->SetInputType(0,type.Get(),0);if(FAILED(hr))return int(hr);
    hr=output_type();if(FAILED(hr))return int(hr);
    ComPtr<IMFAttributes> attributes;if(SUCCEEDED(codec->GetAttributes(&attributes)))attributes->SetUINT32(MF_LOW_LATENCY,TRUE);
    parameters=config.annex();codec->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING,0);codec->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM,0);return 0;
  }
  int output(std::vector<Picture>& pictures, bool wait=false){
    auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(20);const auto before=pictures.size();
    for(int i=0;i<32;++i){MFT_OUTPUT_STREAM_INFO info{};auto hr=codec->GetOutputStreamInfo(0,&info);if(FAILED(hr))return int(hr);
      ComPtr<IMFSample> sample;ComPtr<IMFMediaBuffer> buffer;
      if(!(info.dwFlags&MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)){
        hr=MFCreateSample(&sample);if(FAILED(hr))return int(hr);
        DWORD size=std::max<DWORD>(info.cbSize,DWORD(stride)*((height+15)&~15u)*3/2);
        if(size>64*1024*1024)return -3004;
        hr=MFCreateMemoryBuffer(size,&buffer);if(FAILED(hr))return int(hr);sample->AddBuffer(buffer.Get());
      }
      MFT_OUTPUT_DATA_BUFFER data{0,sample.Get(),0,nullptr};DWORD flags=0;hr=codec->ProcessOutput(0,1,&data,&flags);
      if(data.pEvents)data.pEvents->Release();
      if(!sample&&data.pSample)sample.Attach(data.pSample);
      if(hr==MF_E_TRANSFORM_NEED_MORE_INPUT){if(wait&&pictures.size()==before&&std::chrono::steady_clock::now()<deadline){std::this_thread::sleep_for(std::chrono::milliseconds(1));continue;}return 0;}
      if(hr==MF_E_TRANSFORM_STREAM_CHANGE){hr=output_type();if(FAILED(hr))return int(hr);continue;}
      if(FAILED(hr)||!sample)return FAILED(hr)?int(hr):-3002;
      hr=sample->ConvertToContiguousBuffer(&buffer);if(FAILED(hr))return int(hr);
      BYTE* bytes=nullptr;DWORD capacity=0,length=0;hr=buffer->Lock(&bytes,&capacity,&length);if(FAILED(hr))return int(hr);
      const size_t required=size_t(stride)*height*3/2;
      if(length<required||pictures.size()>=16){buffer->Unlock();return -3004;}
      LONGLONG tag=0;sample->GetSampleTime(&tag);Picture p{3,0,uint32_t(tag),width,height,{}};p.bytes.resize(size_t(width)*height*3/2);
      for(UINT32 row=0;row<height;++row)memcpy(p.bytes.data()+size_t(row)*width,bytes+size_t(row)*stride,width);
      for(UINT32 row=0;row<height/2;++row)memcpy(p.bytes.data()+size_t(width)*height+size_t(row)*width,bytes+size_t(stride)*height+size_t(row)*stride,width);
      buffer->Unlock();pictures.push_back(std::move(p));
    }return -3005;
  }
  int decode(const std::vector<uint8_t>& avcc,uint32_t tile,uint32_t tag,std::vector<Picture>& pictures){
    if(!codec||tile!=0)return -3001;// Explicit AU delimiters keep the streaming MFT from buffering the final
    // slice until a later network packet. Input timestamps are monotonic 100ns.
    auto data=annex(avcc);data.insert(data.end(),{0,0,0,1,9,0xf0});data.insert(data.begin(),{0,0,0,1,9,0xf0});if(first||(avcc.size()>4&&(avcc[4]&31)==5)){data.insert(data.begin(),parameters.begin(),parameters.end());first=false;}
    ComPtr<IMFMediaBuffer> buffer;auto hr=MFCreateMemoryBuffer(DWORD(data.size()),&buffer);if(FAILED(hr))return int(hr);
    BYTE* bytes=nullptr;hr=buffer->Lock(&bytes,nullptr,nullptr);if(FAILED(hr))return int(hr);memcpy(bytes,data.data(),data.size());buffer->Unlock();buffer->SetCurrentLength(DWORD(data.size()));
    ComPtr<IMFSample> sample;hr=MFCreateSample(&sample);if(FAILED(hr))return int(hr);sample->AddBuffer(buffer.Get());sample->SetSampleTime(sequence++ * 166667);sample->SetSampleDuration(166667);
    if(avcc.size()>4 && (avcc[4]&31)==5)sample->SetUINT32(MFSampleExtension_CleanPoint,TRUE);
    hr=codec->ProcessInput(0,sample.Get(),0);if(hr==MF_E_NOTACCEPTING){int status=output(pictures);if(status<0)return status;hr=codec->ProcessInput(0,sample.Get(),0);}
    if(FAILED(hr))return int(hr);return output(pictures,true);
  }
};
}
