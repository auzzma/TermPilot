# Synthetic media fixtures

## Production shared UDP broker acceptance (macOS)

The macOS engine now starts its own `screen-media-broker` mode. One broker owns
the fixed UDP ports and authenticates same-user Unix-stream clients. Each stream
is a session lease; EOF unregisters its routes, and an idle broker exits after
five seconds. Workers keep authentication, encryption keys, codecs and control
TCP connections separate. No Python broker or socket interposer is used by the app.
Windows and mobile clients retain their existing transport.

```sh
python3 tests/media-codec/test_shared_udp_startup.py target/release/termpilot-engine
python3 tests/media-codec/test_shared_udp_production_live.py \
  --hosts AUTHORIZED_MAC_A AUTHORIZED_MAC_B \
  --output validation/shared-udp-production --seconds 60 --reconnects 30
```

The first test uses local fixture addresses and no saved credentials. The live
test reads only the two explicitly selected hosts' credentials into private
stdin. It checks both codecs, four resolutions, duplicate-target rejection,
thirty reconnects with the other session kept alive, worker termination,
shared-service termination/restart, and final port/lock release. `--viewer`
accepts the read-only Metal viewer described below. Run fault-injection tests
without unrelated HP sessions: intentionally terminating a shared broker affects
every session attached to that broker.

Native automatic recovery uses an opt-in Swift test, after building test helpers
with the repository's normal Release/DEBUG test configuration:

```sh
python3 tests/media-codec/test_shared_udp_native_live.py \
  --hosts AUTHORIZED_MAC_A AUTHORIZED_MAC_B \
  --engine target/release/termpilot-engine \
  --output validation/shared-udp-production/native-recovery.log
```

This runner sends credentials through a user-owned 0600 FIFO. The Swift test
requires actual frames in both native runtimes, kills their shared broker,
requires automatic recovery with a new common broker PID, and reconnects A while
B remains connected. Clipboard synchronization is disabled, audio is muted, and
the tests send no remote keyboard/mouse input or files. No remote media is saved.

## Opt-in shared UDP broker experiment (macOS)

`test_shared_udp_live.py` runs one independent `shared_udp_broker_probe.py`
process owning UDP 5900/5901, plus one unchanged production engine process per
explicitly authorized Mac. The test-only `broker_transport_probe.c` adapter
connects each engine's media sockets to separate loopback UDP IPC endpoints.
The broker forwards the original encrypted datagrams by remote IP, remote port
and local media channel. Authentication/control TCP connections remain direct.
The broker holds the existing application-wide lock; worker locks are isolated.

```sh
python3 tests/media-codec/test_shared_udp_broker.py
python3 tests/media-codec/test_shared_udp_live.py \
  --hosts AUTHORIZED_MAC_A AUTHORIZED_MAC_B \
  --output validation/shared-udp-experiment --seconds 60
```

Optional read-only Metal windows use the same texture layout and color conversion
as the production renderer, without importing credentials, input or clipboard:

```sh
xcrun swiftc -swift-version 5 -O -module-cache-path /tmp/tp-broker-viewer-cache \
  tests/media-codec/broker_viewer.swift -o /tmp/TermPilotBrokerViewer
python3 tests/media-codec/test_shared_udp_live.py \
  --hosts AUTHORIZED_MAC_A AUTHORIZED_MAC_B \
  --output validation/shared-udp-experiment --seconds 60 \
  --viewer /tmp/TermPilotBrokerViewer
```

The sequence covers H.264 and H.265 simultaneously, clean single-worker exit,
reconnection, intentional single-worker termination and recovery. The first
codec also reconnects A at 1280×720, 2560×1440 and 3840×2160 while B stays at
1920×1080. The test asserts independent worker PIDs, complete initial decoded
tile coverage, continued authenticated audio and decode progress when video
arrives; an idle screen with no video packets is not treated as a disconnect.
Results include per-route traffic/drop counters and per-worker decoder stats.

This historical experiment proves the transport/process architecture. Run it
with the pre-broker engine binary recorded in its report: loopback endpoint
learning and independent worker locks belong only to its test scaffolding.
The production implementation and its separate acceptance tests are above.
The test does not exercise remote keyboard/mouse, clipboard or file transfer;
no passwords, media payloads, screenshots or audio recordings are stored.

## Opt-in local UDP port experiment (macOS)

`test_udp_ports_live.py` compares fixed local UDP 5900/5901 against independent
OS-assigned local ports, using an existing production `termpilot-engine` binary.
It compiles the test-only `udp_port_probe.c` interposer and self-test with Xcode.
Only the two IPv4 UDP `bind` calls change; remote endpoints, authentication,
media offers, encryption and decoding remain unchanged. The interposer is loaded
only into test child processes and is never linked into the application.

Use an explicitly authorized test Mac with saved screen-sharing credentials:

```sh
python3 tests/media-codec/test_udp_ports_live.py --host TEST_MAC_IP \
  --output validation/udp-port-experiment --seconds 30
```

The default sequence is fixed / ephemeral / ephemeral / fixed. During ephemeral
runs, passive listeners on the original local ports count only datagrams from
the selected host. They save counts and RTP header classifications, never packet
contents. Repeat without those listeners to rule out observation effects:

```sh
python3 tests/media-codec/test_udp_ports_live.py --host TEST_MAC_IP \
  --output validation/udp-port-experiment-no-observer --seconds 20 \
  --modes ephemeral fixed --codecs h264 h265 --no-observe-fixed-ports
```

The probe opens and closes virtual-display sessions and can blank the remote
physical display. Run it without another active HP session; it retains the
application's existing global lock. Credentials and decoded media stay in memory;
there is no keyboard/mouse input, clipboard access or file transfer. A static
desktop may stop sending video, so media acceptance checks successful decoded
tile coverage and the observation duration rather than a fixed frame-rate floor.
An exit status of zero means the comparison completed; inspect `mediaPassed` in
each result to determine whether that port mode actually delivered media.

`test_codec.py` exercises HEVC 4:4:4 frames with tile/sequence tags, the Apple AAC-ELD-SBR AudioSpecificConfig, PCM output, and malformed length rejection. It runs in the native Windows build before packaging.

`eld-sbr.fixture` contains a generated 440 Hz stereo tone, no recordings. The first byte is the AudioSpecificConfig length, followed by that configuration and repeated big-endian u16 packet lengths + encoded access units. `generate_audio.cpp` regenerates it with the vendored FDK AAC encoder (48 kHz, ELD, single-rate SBR, 480 samples, 128 kbps). Link this development-only generator against FDK AAC; it is not shipped as an application executable.

`hevc-recovery.fixture` is a synthetic 96×64 HEVC 4:4:4 animation (200 frames,
IDRs at 0/90/180), stored as repeated big-endian u32 length + NAL. No screen
recordings or credentials. `test_recovery.py`, also called by `test_codec.py`,
checks the clean stream, a lost reference frame, and repeated losses. Suppressed
damaged pictures exhaust libde265's DPB in the old adapter; subsequent IDRs must
resume decoding with the same tile/sequence tags and cached VPS/SPS/PPS.

Regenerate with FFmpeg/libx265:
```
ffmpeg -f lavfi -i 'testsrc2=size=96x64:rate=30' -frames:v 200 -pix_fmt yuv444p \
  -c:v libx265 -preset ultrafast \
  -x265-params 'lossless=1:keyint=90:min-keyint=90:scenecut=0:bframes=0:repeat-headers=1:pools=1' \
  -f hevc recovery.hevc
```
Split the Annex B start codes, retain NAL types 0–34, and write each NAL prefixed
by its u32 big-endian length. FFmpeg is only a fixture generator, never an app
dependency. Android runs this fixture through `tests/mobile/media_probe.c` and
the packaged `libtermpilot_media.so` via the NDK-built test executable.

## Opt-in Apple H.264 negotiation validation

`engines/rust/examples/apple_codec_probe.rs` reuses the production SRP,
encrypted control connection and authenticated SRTP implementation, with an
isolated offer wrapper. The probe retains its original HEVC baseline independently
of the application, whose default is now H.264. The H.264 bank parameters are derived from
the iShareScreen revision recorded in `engines/rust/UPSTREAM`.

On the authorized developer Mac, using its saved test-host credentials:

```sh
cargo build -p termpilot-engine --release --example apple_codec_probe --locked
python3 tests/media-codec/test_apple_codec_offer.py --codec hevc --seconds 12 --output validation/apple-h264/hevc.json
python3 tests/media-codec/test_apple_codec_offer.py --codec h264 --seconds 30 --output validation/apple-h264/h264.json
```

The Python runner requires `cryptography` and the developer's `ffprobe`. Neither
is an application runtime dependency. Compressed remote frames stay in memory;
only codec metadata, packet/frame counts and decoder diagnostics are saved.
The probe sends no keyboard/mouse input and performs no clipboard/file transfer.
It exclusively binds local UDP 5900/5901 and should run without another screen
sharing test connection.

The one-picture H.264 answer may report tile count zero. The probe accepts this
only when H.264 and one picture were explicitly requested; verify the actual
source count and decoded full-picture dimensions. Four-picture mode can use
FU-B/STAP-B, while one-picture mode uses FU-A/single NALs on the tested host.
An `avcC` response alone does not prove successful decoding: the runner requires
real H.264 frames from an independent decoder. This does not validate Android
MediaCodec, visual quality, interactive latency, or sustained device FPS.

## Production AVC adapters and renderer

`h264.fixture` is a synthetic 96×64, 30-frame H.264 animation, never a screen
recording. Its records are big-endian u32 length + payload. The first payload is
length-prefixed SPS/PPS; subsequent payloads are access units of length-prefixed
NALs. Generate with FFmpeg/libx264 `testsrc2`, `-tune zerolatency`, `-color_range pc`
and `-x264-params aud=1:keyint=15`; group slices by AUD and retain parameter sets
separately. FFmpeg is used only during development.

- `test_avc.py <termpilot-media.exe>` checks Windows native AVC output, complete
  frame count, NV12 layout and changing pixels.
- `tests/mobile/avc_probe.c` runs the same fixture through the mobile C ABI;
  iOS `AVCDecoderTests` and an NDK-built Android probe use it.
- `render_fixture.cjs <output.html>` produces a synthetic WebGL2 acceptance page
  from the Windows renderer. Check the JSON result in `<pre>` for HEVC four-tile
  display, AVC full-picture display, orientation and switching back to HEVC.
- `test_clean_live.py --codec h264|h265` exercises the production engine against
  the authorized Mac. Supply `TERMPILOT_TEST_ENGINE`; pixels stay in memory.

Real Android UDP reception and Pixel performance require device/network testing;
native decoder fixture success is not a substitute for that acceptance.

`test_android_avc_live.py` captures authenticated Apple AVC in memory on the Mac
and replays complete access units into the actual Android native adapter over
an adb pipe. Build `tests/mobile/avc_stream_probe.c` with the NDK, linking
`libtermpilot_media.so` and `libdl`; push it as `avc_stream_probe` alongside the
adapter and its dependencies under `/data/local/tmp/termpilot-avc18/` on the
ARM64 `emulator-5554`. Then run:

```sh
python3 tests/media-codec/test_android_avc_live.py --seconds 15 \
  --output validation/android-avc-black-screen/android-live.json
```

Optional `--compare-dir` replays the same in-memory stream with another adapter.
No pixels, compressed stream or credentials are persisted. The report requires
every submitted frame to be returned, validates 4:2:0 dimensions and records the
selected native codec. Per-call time measures time spent in the adapter call,
not the asynchronous decoder's total CPU time. This test uses the Mac's network
connection and an emulator decoder; it does not prove a physical Pixel's UDP,
hardware-decoder compatibility, rendering latency or sustained FPS.
