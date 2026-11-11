# Native media decoder

A standalone MIT-licensed media utility. It has no network, desktop, filesystem,
credential or screen-sharing protocol access. It decodes length-delimited raw
HEVC NAL units, AVC access units and MPEG-4 AAC access units over stdin/stdout. The codec libraries
are replaceable shared libraries, licensed separately; their unmodified source
and notices live under `vendor/` and ship with the application.

All integer fields are little-endian u32. Request: operation, caller tile tag,
caller sequence tag, payload length, payload. Operations: 1 = configure video
(big-endian length-prefixed HEVC VPS/SPS/PPS or AVC SPS/PPS), 2 = decode video
(one raw HEVC NAL or one AVC access unit containing big-endian length-prefixed NALs),
3 = configure AAC (AudioSpecificConfig), 4 = decode one AAC access unit.
Response: signed status (zero on success), output count, then each output:
kind, tile tag, sequence tag, width, height, byte length, bytes. Kind 1 is NV24
(full-range Y plane followed by interleaved U/V, all rows tightly packed).
Kind 2 is interleaved stereo f32 PCM, width = sample frames, height = sample rate.
Kind 3 is NV12 (full-range Y followed by half-width, half-height interleaved U/V,
tightly packed). AVC uses a single full picture and tile tag zero.
Input is capped at 16 MiB; decoded images at 4096 × 2160; PCM at 8,192 samples.
EOF shuts down the utility. Diagnostics go to stderr only.

Build using CMake; production builds use the matching Windows x64/ARM64 compiler.
The same source can be built on macOS for decoder fixture tests.

AVC uses the Windows Media Foundation H.264 decoder or Android NDK MediaCodec
(`video/avc`); Android checks the decoder's actual output layout before copying
I420/NV12 into packed NV12. HEVC 4:4:4 retains libde265. The standalone macOS
utility tests HEVC/AAC only: production macOS and iOS use the separate
VideoToolbox adapter in `engines/rust/platform/macos/MediaAdapter.swift` for both
AVC and HEVC. Selecting a system API does not itself prove hardware decoding on
a particular device.
