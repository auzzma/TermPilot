// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>
#include <libde265/de265.h>
#include <aacdecoder_lib.h>

struct Picture {
  uint32_t kind, tile, tag, width, height;
  std::vector<uint8_t> bytes;
};
#include "avc.hpp"
struct Decoder {
  std::unique_ptr<avc::Decoder> avc_video;
  de265_decoder_context* video = nullptr;
  std::vector<uint8_t> video_parameters;
  bool waiting_for_keyframe = false;
  HANDLE_AACDECODER audio = nullptr;
  ~Decoder() { if (video) de265_free_decoder(video); if (audio) aacDecoder_Close(audio); }
  int configure_video(const std::vector<uint8_t>& data) {
    if (data.size() > 65536 || data.size() < 6) return -2;
    avc_video.reset();
    if ((data[4] & 31) == 7) {
      if(video){de265_free_decoder(video);video=nullptr;}
      try {avc::Config config(data);avc_video=std::make_unique<avc::Decoder>();return avc_video->configure(config);}catch(...){avc_video.reset();return -3000;}
    }
    video_parameters = data;
    waiting_for_keyframe = false;
    return reset_video();
  }
  int reset_video() {
    const auto& data = video_parameters;
    if (video) de265_free_decoder(video);
    video = de265_new_decoder();
    if (!video) return -1;
    auto limits = *de265_get_security_limits(video);
    limits.max_image_size_pixels = 4096 * 2160;
    limits.max_NAL_size_bytes = 16 * 1024 * 1024;
    limits.max_SEI_messages = 256;
    de265_set_security_limits(video, &limits);
    de265_set_parameter_bool(video, DE265_DECODER_PARAM_SUPPRESS_FAULTY_PICTURES, 1);
    de265_start_worker_threads(video, std::min(8u, std::max(1u, std::thread::hardware_concurrency())));
    size_t offset = 0, count = 0;
    while (offset + 4 <= data.size()) {
      uint32_t n = uint32_t(data[offset]) << 24 | uint32_t(data[offset+1]) << 16 |
                   uint32_t(data[offset+2]) << 8 | uint32_t(data[offset+3]);
      offset += 4;
      if (n < 2 || n > data.size() - offset || ++count > 32) return -2;
      int error = de265_push_NAL(video, data.data() + offset, int(n), 0, nullptr);
      if (error != DE265_OK) return -1000 - error;
      offset += n;
    }
    return offset == data.size() && count >= 3 ? 0 : -2;
  }
  int video_packet(const std::vector<uint8_t>& data, uint32_t tile, uint32_t tag, std::vector<Picture>& output) {
    if (data.size() < 2 || data.size() > 16 * 1024 * 1024 || tile >= 16) return -2;
    if (avc_video) {try{return avc_video->decode(data,tile,tag,output);}catch(...){return -3000;}}
    if (waiting_for_keyframe) {
      // Predicted pictures still depend on the lost reference. Do not refill the
      // broken DPB while waiting for the IRAP requested by the caller's FIR.
      unsigned kind = (data[0] >> 1) & 63;
      if (kind < 16 || kind > 23) return 0;
      int status = reset_video();
      if (status < 0) return status;
      waiting_for_keyframe = false;
    }
    if (!video) return -2;
    int status = decode_video_packet(data, tile, tag, output);
    if (status < 0) {
      // libde265 can keep suppressed, damaged reference pictures in its DPB.
      // Once full it rejects even new IDRs. A FIR alone cannot recover it.
      de265_free_decoder(video);
      video = nullptr;
      waiting_for_keyframe = true;
    }
    return status;
  }
  int decode_video_packet(const std::vector<uint8_t>& data, uint32_t tile, uint32_t tag, std::vector<Picture>& output) {
    auto stamp = (uint64_t(tile) << 32) | tag;
    int result = de265_push_NAL(video, data.data(), int(data.size()), de265_PTS(stamp), nullptr);
    if (result != DE265_OK) return -1000 - result;
    de265_push_end_of_frame(video);
    for (unsigned iteration = 0; iteration < 256; ++iteration) {
      int more = 0;
      auto error = de265_decode(video, &more);
      while (auto picture = de265_peek_next_picture(video)) {
        int width = de265_get_image_width(picture, 0), height = de265_get_image_height(picture, 0);
        int cw = de265_get_image_width(picture, 1), ch = de265_get_image_height(picture, 1);
        if (width <= 0 || height <= 0 || width > 4096 || height > 2160 || cw <= 0 || ch <= 0 ||
            de265_get_bits_per_pixel(picture, 0) != 8 || output.size() >= 16) return -3;
        auto pts = uint64_t(de265_get_image_PTS(picture));
        Picture p{1, uint32_t(pts >> 32), uint32_t(pts), uint32_t(width), uint32_t(height), {}};
        p.bytes.resize(size_t(width) * height * 3);
        int ys = 0, us = 0, vs = 0;
        auto y = de265_get_image_plane(picture, 0, &ys);
        auto u = de265_get_image_plane(picture, 1, &us);
        auto v = de265_get_image_plane(picture, 2, &vs);
        if (!y || !u || !v || ys < width || us < cw || vs < cw) return -3;
        for (int row = 0; row < height; ++row) {
          memcpy(p.bytes.data() + size_t(row) * width, y + size_t(row) * ys, width);
          auto uv = p.bytes.data() + size_t(width) * height + size_t(row) * width * 2;
          if (cw == width && ch == height) {
            // Apple's 4:4:4 tiles need interleaving only. Keep integer scaling
            // out of this hot loop so ARM64 can vectorize the copy.
            auto ur = u + size_t(row) * us;
            auto vr = v + size_t(row) * vs;
            for (int col = 0; col < width; ++col) {
              uv[col * 2] = ur[col];
              uv[col * 2 + 1] = vr[col];
            }
            continue;
          }
          for (int col = 0; col < width; ++col) {
            uv[col * 2] = u[size_t(row * ch / height) * us + col * cw / width];
            uv[col * 2 + 1] = v[size_t(row * ch / height) * vs + col * cw / width];
          }
        }
        output.push_back(std::move(p));
        de265_release_next_picture(video);
      }
      if (error == DE265_ERROR_WAITING_FOR_INPUT_DATA) return 0;
      if (error != DE265_OK && !de265_isOK(error)) return -1000 - error;
      if (!more) return 0;
    }
    return -4;
  }
  int configure_audio(std::vector<uint8_t>& data) {
    if (data.empty() || data.size() > 128) return -2;
    if (audio) aacDecoder_Close(audio);
    audio = aacDecoder_Open(TT_MP4_RAW, 1);
    if (!audio) return -1;
    UCHAR* bytes = data.data(); UINT size = UINT(data.size());
    auto error = aacDecoder_ConfigRaw(audio, &bytes, &size);
    return error == AAC_DEC_OK ? 0 : -2000 - int(error);
  }
  int audio_packet(std::vector<uint8_t>& data, std::vector<Picture>& output) {
    if (!audio || data.empty() || data.size() > 65536) return -2;
    UCHAR* bytes = data.data(); UINT size = UINT(data.size()), valid = size;
    auto error = aacDecoder_Fill(audio, &bytes, &size, &valid);
    if (error != AAC_DEC_OK || valid) return -2000 - int(error);
    std::array<INT_PCM, 8192> samples{};
    error = aacDecoder_DecodeFrame(audio, samples.data(), int(samples.size()), 0);
    if (error == AAC_DEC_NOT_ENOUGH_BITS) return 0;
    if (error != AAC_DEC_OK) return -2000 - int(error);
    auto info = aacDecoder_GetStreamInfo(audio);
    if (!info || info->numChannels != 2 || info->frameSize <= 0 || info->frameSize > 4096 || info->sampleRate != 48000) return -3;
    Picture p{2, 0, 0, uint32_t(info->frameSize), uint32_t(info->sampleRate), {}};
    p.bytes.resize(size_t(info->frameSize) * 2 * sizeof(float));
    for (int i = 0; i < info->frameSize * 2; ++i) {
      float sample = float(samples[i]) / 32768.0f;
      memcpy(p.bytes.data() + size_t(i) * sizeof(float), &sample, sizeof(float));
    }
    output.push_back(std::move(p));
    return 0;
  }
};
