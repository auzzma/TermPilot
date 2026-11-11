// SPDX-License-Identifier: MIT
// Generic stdin/stdout media conversion; no application or networking APIs.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <vector>
#include <libde265/de265.h>
#include <aacdecoder_lib.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static uint32_t word(const uint8_t* p) {
  return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
static void put(uint32_t n) {
  uint8_t b[] = {uint8_t(n), uint8_t(n >> 8), uint8_t(n >> 16), uint8_t(n >> 24)};
  if (fwrite(b, 1, 4, stdout) != 4) throw std::runtime_error("output closed");
}
#include "decoder.hpp"

int main() {
#ifdef _WIN32
  _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
#endif
  try {
    Decoder decoder;
    std::array<uint8_t, 16> header{};
    while (true) {
      size_t got = fread(header.data(), 1, header.size(), stdin);
      if (!got && feof(stdin)) return 0;
      if (got != header.size()) return 2;
      auto kind = word(header.data()), tile = word(header.data()+4), tag = word(header.data()+8), length = word(header.data()+12);
      if (!length || length > 16 * 1024 * 1024) return 2;
      std::vector<uint8_t> data(length);
      if (fread(data.data(), 1, data.size(), stdin) != data.size()) return 2;
      std::vector<Picture> output;
      int status = -2;
      if (kind == 1) status = decoder.configure_video(data);
      if (kind == 2) status = decoder.video_packet(data, tile, tag, output);
      if (kind == 3) status = decoder.configure_audio(data);
      if (kind == 4) status = decoder.audio_packet(data, output);
      put(uint32_t(status)); put(uint32_t(output.size()));
      for (auto& picture : output) {
        put(picture.kind); put(picture.tile); put(picture.tag); put(picture.width); put(picture.height); put(uint32_t(picture.bytes.size()));
        if (fwrite(picture.bytes.data(), 1, picture.bytes.size(), stdout) != picture.bytes.size()) return 3;
      }
      if (fflush(stdout)) return 3;
    }
  } catch (...) { return 4; }
}
