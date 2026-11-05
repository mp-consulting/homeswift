# Return audio: HomeKit two-way audio for camera plugins (clean room)

## 0. Provenance

Written by the spec writer; contains **no source code** from any third party. This spec is shared by `ImouTalk.md` and
`ReolinkTalk.md`: it says what HomeKit sends back to a camera while someone talks in the Home app, how `HomeswiftFFmpeg`
turns it into PCM, how a plugin gets that PCM, and how a plugin re-encodes it for a camera. Interface identifiers (SDP
attributes, FFmpeg flags, codec names) are quoted exactly because they are the interface. **Recommendation** marks the
spec writer's design. The test vectors in section 8 were computed by the spec writer with a scratch script and checked
against FFmpeg 7 (`pcm_alaw`, `pcm_mulaw` encoders; the `adpcm_ima_wav` decoder).

| Source | What was taken from it | Version / commit | Licence |
|---|---|---|---|
| This repository: `Plugins/IPCameras/Sources/CameraStreamer.swift`, `FFmpegArguments.swift` (`returnAudio`, `returnAudioSDP`), `FFmpegCapabilities.swift` (`aacELDDecoder`) | How return audio is received today (`CameraFFmpeg.md` §7.7): the SDP, the `RtpDemuxer`, start on the first packet | `main` at `87d72d0a` | the project's own |
| This repository: `Sources/HomeswiftFFmpeg/RTSPCamera.swift`, `RTP.swift`; `Sources/Homeswift/Camera/CameraTypes.swift`, `CameraController.swift` | `RTSPCameraStreamer`'s sessions and ports, `AudioInfo`, `AudioStreamingOptions.twoWayAudio`, the Speaker service | same | the project's own |
| ITU-T G.711 (1988), IMA "Recommended Practices for Enhancing Digital Audio Compatibility in Multimedia Systems" (1992, the IMA/DVI ADPCM algorithm), RFC 3550, RFC 3640, RFC 3711 | Public standards: the A-law/µ-law and IMA ADPCM algorithms, RTP, AAC over RTP, SRTP | — | standards documents |

No Homebridge or HAP-NodeJS code was read for this spec beyond what `CameraFFmpeg.md` already describes.

## 1. Scope

- Receiving HomeKit's return audio on a live stream of an `RTSPCameraStreamer` (Imou and others) and of a plugin's own
  streamer (Reolink's `ReolinkStreamer`, which is not an `RTSPCameraStreamer` today), decoding it to PCM with FFmpeg.
- Handing the plugin a stream of PCM frames per **Talk** (one burst of speech, from the first packet to an idle gap).
- Encoders a plugin needs: G.711 A-law and µ-law, IMA ADPCM (DVI-4) in blocks, AAC (ADTS).

Not in scope: sending audio to a specific camera (`ImouTalk.md`, `ReolinkTalk.md`), HomeKit Secure Video, the camera's
own microphone audio towards HomeKit (already done by `RTSPCameraArguments.live`).

Vocabulary (Recommendation, for `GLOSSARY.md`): **Talk**, one continuous period during which HomeKit sends return audio
on a live stream; **Return audio**, the audio HomeKit sends to the accessory.

## 2. What HomeKit sends

### 2.1 Negotiation (existing behaviour)

- The camera advertises two-way audio with `AudioStreamingOptions(codecs:…, twoWayAudio: true)`. `CameraController` then
  adds a **Speaker** service (Mute, Volume) next to the Microphone; HomeKit shows the talk button only when it exists.
- The codec list is what the accessory accepts in **both** directions. `RTSPCameraStreamer` and `ReolinkStreamer`
  advertise AAC-ELD at 16 kHz only (`AudioStreamingCodec(type: .aacELD, samplerate: [.khz16])`). **Recommendation:**
  keep exactly that for two-way cameras; the return SDP of 3.1 is written for it (Opus is an open question, §9).
- `PrepareStreamRequest.audio` carries the controller's audio port, SRTP suite and the 16-byte key and 14-byte salt.
  The accessory answers with its own audio port (`PrepareStreamResponse.audio.port`, the "audio return port") and, as
  the existing streamers do, the controller's **same** key and salt. HomeKit then encrypts return audio with that key
  and salt (AES_CM_128_HMAC_SHA1_80, RFC 3711).
- `StartStreamRequest.audio` (`AudioInfo`) gives: `codec` (`.aacELD`), `sampleRate` in kHz (16), `channel` (1),
  `pt` (the RTP payload type, normally 110), `packetTime` (ms per packet, usually 30 for AAC-ELD), `maxBitRate`
  (kbit/s, usually 24), `comfortPT` (13) and `comfortNoiseEnabled`.

### 2.2 The packets

| Property | Value |
|---|---|
| Transport | UDP datagrams from the controller to `<accessory address>:<audio return port>` |
| Framing | SRTP and SRTCP **multiplexed on that one port** (`rtcp-mux`); RTP when the second byte & 0x7F is ≥ 90 (or 0), RTCP otherwise; `RtpDemuxer.isRTP` already does this split |
| RTP payload type | `AudioInfo.pt` (110) |
| RTP clock | the sample rate, 16000 Hz |
| Payload | RFC 3640 `AAC-hbr`: a 2-byte AU-headers-length (in bits, 16 for one AU), one 2-byte AU header per access unit (13-bit size, 3-bit index), then the AAC-ELD access units |
| SSRC | the controller's own (not the one in `PrepareStreamResponse`) |
| When | **only while the user holds the talk button** (the existing `CameraStreamer` comment and its behaviour); RTCP keeps coming on the port the whole stream |

Silence while talking is still sent (AAC-ELD frames of silence), so a gap of more than a few packet times means the
user stopped talking (§4.4). Comfort noise (`comfortPT` 13) has not been seen with AAC-ELD; ignore that payload type.

## 3. Decoding with FFmpeg

### 3.1 SDP

FFmpeg reads SRTP from an SDP written to its standard input (the form `FFmpegArguments.returnAudioSDP` already writes),
CRLF line endings, `‹V›` = `IP4` or `IP6`, `‹addr›` = the controller's address (informational), `‹port›` = the loopback
port the demuxer forwards RTP to (3.3), `‹pt›` = `AudioInfo.pt`, `‹key›` = base64 of the 30 bytes key‖salt:

```
v=0
o=- 0 0 IN ‹V› ‹addr›
s=Talk
c=IN ‹V› ‹addr›
t=0 0
m=audio ‹port› RTP/AVP ‹pt›
b=AS:24
a=rtpmap:‹pt› MPEG4-GENERIC/16000/1
a=rtcp-mux
a=fmtp:‹pt› profile-level-id=1;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3; config=F8F0212C00BC00
a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:‹key›
```

`config=F8F0212C00BC00` is the AudioSpecificConfig of HomeKit's AAC-ELD: object type 39 (ER AAC ELD), sampling
frequency index 8 (16 kHz), one channel. It is valid for 16 kHz only, which is why only 16 kHz is offered (2.1). Keep the
space before `config=` (the existing SDP has it and FFmpeg accepts it). Today the existing SDP hard-codes payload type
110; **Recommendation:** fill in `AudioInfo.pt`.

### 3.2 Command line

argv (no shell), in this order:

`-hide_banner -loglevel error -protocol_whitelist pipe,udp,rtp,file,crypto -f sdp ‹decoder› -i pipe:0`
`-vn -sn -dn -ac 1 -ar ‹rate› -acodec pcm_s16le -f s16le -flush_packets 1 pipe:1`

- `‹decoder›`: `-c:a libfdk_aac` when FFmpeg has it, else `-c:a aac_at` on macOS, else nothing (FFmpeg's own `aac`
  decoder handles ER AAC ELD) — exactly `FFmpegCapabilities.aacELDDecoder()`'s rule. **Recommendation:** move that
  probe into `RTSPCameraFFmpeg` as `returnAudioDecoder()` so every plugin shares it.
- `‹rate›`: the plugin's PCM rate, 8000 or 16000 (4.1). FFmpeg resamples.
- With the plugin's `debug`, replace `error` by `level+verbose`.
- The SDP is written to standard input, which is then closed (`endStdin`); PCM comes on standard output.
- Never log the SDP or the argv unredacted: the `inline:` key is a secret (`redactCommandLine` and the existing SDP
  masking in `FFmpegArguments`' redaction).

### 3.3 Keeping FFmpeg alive

FFmpeg's RTP input stops after about five seconds without a packet, and HomeKit sends nothing between Talks. The
existing approach, kept: an `RtpDemuxer` binds the audio return port, forwards RTP to `127.0.0.1:‹rtpPort›` and RTCP to
`‹rtpPort›+1` (two consecutive ports from `RtpPortAllocator.reserve(portCount: 2)`), and replays the last RTCP packet to
the RTP port every 3 s, which FFmpeg ignores as media but which resets its timeout. One FFmpeg runs per live stream,
started on the **first** RTP packet of the stream (not at stream start: FFmpeg must see real packets to find the codec
parameters), and kept until the stream stops. If it exits on its own while the stream runs, the next RTP packet starts
another (the existing `twoWayAudio` task's loop).

### 3.4 From bytes to frames

FFmpeg's standard output is a byte stream of signed 16-bit little-endian mono samples in arbitrary chunk sizes. The
streamer cuts it into **frames of exactly `rate × 20 ms` samples** (160 at 8 kHz, 320 at 16 kHz), keeping a remainder
between chunks (an odd trailing byte included). Each frame gets a timestamp: the number of samples since the start of the
current Talk.

## 4. The interface in `HomeswiftFFmpeg` (Recommendation)

### 4.1 Types

| Type | Members | Meaning |
|---|---|---|
| `ReturnAudioFormat` (struct, Sendable, Equatable) | `sampleRate: Int` (8000 or 16000), `frameDuration: Duration` (20 ms; 10–60 ms accepted, a multiple of 10 ms) | what the plugin wants; `samplesPerFrame` = rate × duration |
| `PCMFrame` (struct, Sendable) | `samples: [Int16]` (mono, exactly `samplesPerFrame`, the last frame of a Talk padded with zeros), `offset: Int` (samples since the Talk began) | one frame |
| `Talk` (struct, Sendable) | `sessionID: String` (HomeKit's stream session), `format: ReturnAudioFormat`, `frames: AsyncStream<PCMFrame>`, `volume: Int` (the Speaker's volume, 0–100, when the Talk began) | one Talk; `frames` finishes when it ends |
| `ReturnAudioHandler` | `@Sendable (Talk) async -> Void` | called once per Talk, on its own task; when it returns early the remaining frames are dropped |
| `ReturnAudioOptions` (struct) | `format: ReturnAudioFormat`, `idleTimeout: Duration` (default 1.0 s), `maximumTalk: Duration` (default 10 min), `handler: ReturnAudioHandler` | given to the streamer |

`RTSPCameraStreamer.init` gains `returnAudio: ReturnAudioOptions? = nil`. With it, the plugin also sets
`twoWayAudio: true` in its `AudioStreamingOptions` (that is what creates the Speaker service; the streamer does not
change the accessory). A shared `ReturnAudioReceiver` (an actor in `HomeswiftFFmpeg`) holds 3.1–3.4 and 4.2, so that a
plugin with its own streamer (Reolink) uses the same code: it is created at stream start with the prepared audio return
port, the controller's address and key, `AudioInfo`, the `RtpPortAllocator`, the `RTSPCameraFFmpeg` and the options,
and closed at stream stop.

### 4.2 Behaviour

1. **Prepare**: unchanged (the audio return port is already reserved).
2. **Start**: if `returnAudio` is set and the Speaker is not muted, the receiver binds the demuxer on the audio return
   port and reserves the loopback pair. It does not start FFmpeg. A bind failure is logged once ("two-way audio
   unavailable for this stream") and the video stream goes on.
3. **First RTP packet**: start FFmpeg (3.2, 3.3) if it is not running; begin a Talk: create its `AsyncStream`
   (buffering the newest 50 frames, one second, so a slow camera drops old audio rather than piling up latency) and call
   the handler on a new task.
4. **Each further RTP packet** pushes the Talk's idle deadline to now + `idleTimeout`. Packets are counted, not
   inspected; FFmpeg does the decoding.
5. **Frames** from FFmpeg go to the current Talk. Frames that arrive while no Talk is open (FFmpeg flushing late) are
   dropped.
6. **End of Talk**: when `idleTimeout` passes with no RTP packet, or `maximumTalk` is reached, or the Speaker is muted,
   or the stream stops: flush the partial frame (zero-padded), finish the `AsyncStream`. The next RTP packet begins a
   new Talk (with the same FFmpeg).
7. **Stop** (HomeKit's stop, the inactivity watcher, FFmpeg failure of the video): finish the Talk, close the demuxer,
   stop FFmpeg (`stop()`: `q`, then SIGKILL after 2 s), release the two loopback ports.
8. **No audio ever arrives**: nothing happens: no FFmpeg, no Talk, no log line above debug.
9. **FFmpeg cannot decode** (it exits within 2 s of starting, twice in a row on one stream): log one error naming the
   decoder (`libfdk_aac` / `aac_at` / FFmpeg's own), stop trying for the rest of that stream.
10. **Volume**: HomeKit's Speaker Volume (`CameraController.onSpeakerChange`) is passed as `Talk.volume`; the plugin
    decides whether to set the camera's speaker volume or to scale samples (§5.5). Mute ends a running Talk at once.

Timings are multiplied by the plugin's `timeScale` in tests, like the inactivity timeout.

### 4.3 What a plugin's handler does

Open the camera's talk channel when the Talk begins (Reolink `TalkConfig`, Dahua `postAudio`), encode and send each
frame as it comes, and close the channel when `frames` ends. A camera that cannot open its channel makes the handler
return at once; the receiver drops that Talk's frames and tries again on the next Talk (no retry inside one Talk). The
handler must never block the frames' producer: the stream drops the oldest frames when full (4.2 step 3).

## 5. Re-encoding PCM for a camera

| Target | Where | Why |
|---|---|---|
| G.711 A-law (PCMA), 8 kHz | **Swift** | a few lines per sample, deterministic, no process |
| G.711 µ-law (PCMU), 8 kHz | **Swift** | same |
| IMA ADPCM, DVI-4 blocks (Reolink) | **Swift** | FFmpeg's `adpcm_ima_wav` encoder only takes a power-of-two `-block_size` (32–8192) and Reolink needs 516-byte blocks (`ReolinkTalk.md` §4); FFmpeg 7 refuses 516 with "block size must be power of 2" (checked) |
| AAC-LC in ADTS (Dahua `Audio/AAC`, other cameras) | **FFmpeg** | an encoder is not worth writing: a second process reads PCM on stdin and writes ADTS on stdout (5.4) |
| G.726 | FFmpeg (`g726` encoder) if a camera ever needs it | not needed by the plugins specified |

### 5.1 G.711 A-law (Swift)

For each 16-bit sample `s`: take the 13-bit value `s >> 3` (arithmetic shift). Sign bit = `0x80` when it is ≥ 0, else
0, and for a negative value use `−v − 1`. Clamp the magnitude to `0xFFF`. Segment: if the magnitude < 32, the code is
`magnitude >> 1`; otherwise find the segment `seg` (1–7) such that `magnitude >> 5` has its highest set bit at position
`seg − 1`, and the code is `seg << 4 | (magnitude >> seg) & 0x0F`. Output `(code | sign) XOR 0x55`.

### 5.2 G.711 µ-law (Swift)

On the 14-bit value `p = s >> 2` (arithmetic): if `p < 0`, use `−p` and mask `0x7F`, else mask `0xFF`. Clamp to 8159, add
33. Segment `seg` = the first of the upper bounds `0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF` that is ≥ the
value. Output `(seg << 4 | (value >> (seg + 1)) & 0x0F) XOR mask`. (This is the classic reference formulation; it is
what FFmpeg's `pcm_mulaw` gives, including `−1 → 0x7E`.)

### 5.3 IMA ADPCM, DVI-4 block layout (Swift)

The standard IMA algorithm (step table of 89 values from 7 to 32767, index adjustments −1, −1, −1, −1, 2, 4, 6, 8 for
codes 0–7), mono, in the block layout of Microsoft's IMA ADPCM WAV format (`adpcm_ima_wav`):

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | first sample of the block, int16 little-endian (it is the predictor; it is **not** encoded again) |
| 2 | 1 | step index at the block start, 0–88 |
| 3 | 1 | reserved, 0 |
| 4 | n | 4-bit codes, two per byte, **low nibble first** |

A block of `4 + n` bytes holds `2n + 1` samples. Encoding one sample: difference `d` = sample − predictor; code bit 3 =
sign; then bits 2, 1, 0 by comparing `|d|` with step, step/2, step/4 (subtracting each time it is reached); the
reconstructed difference is `step/8` plus the parts reached; update the predictor (clamped to int16) **with the
reconstructed value**, then the index (clamped 0–88). The encoder carries the step index from one block to the next
(the block header records it); the predictor restarts at each block's first sample. The first block of a Talk starts
at index 0.

### 5.4 AAC (FFmpeg)

`-hide_banner -loglevel error -f s16le -ar ‹rate› -ac 1 -i pipe:0 -c:a aac -profile:a aac_low -b:a 32k -f adts -flush_packets 1 pipe:1`.
Write frames to stdin as they come (`writeStdin`), close stdin at the end of the Talk, read ADTS from stdout until FFmpeg
exits. Each ADTS frame is 1024 samples (64 ms at 16 kHz). A camera that wants AAC gets whole ADTS frames: split
stdout at ADTS sync words (12 bits `0xFFF`, frame length in the 13 bits starting at bit 30 of the header).

### 5.5 Volume

HomeKit's Speaker Volume is 0–100. **Recommendation:** when the camera has a speaker-volume setting (Reolink
`talkAndReplyVolume`), leave the samples alone and do not write the setting either (HomeKit's slider is rarely touched
and a write changes the device for every client); otherwise scale samples by `volume / 100` before encoding (an
integer multiply and a clamp). Never amplify above 100 %.

## 6. Logging and secrets

The SDP carries the SRTP key: never log it (mask `inline:…`). Log at info "Talk started" / "Talk ended (n s)" once per
Talk, at debug the packet and frame counts. Audio content is never logged.

## 7. Tests (Recommendation)

- A fake controller: send SRTP AAC-ELD packets to the audio return port. Generating real AAC-ELD needs FFmpeg with
  `libfdk_aac`; instead, the receiver's tests inject a fake "decoder process" through a closure (the same seam
  `RTSPCameraFFmpeg` uses for codecs) that emits PCM bytes on stdout, and assert framing, Talk boundaries and timeouts.
  One test that runs the real FFmpeg is skipped when no AAC-ELD encoder is installed.
- Framing: stdout chunks of 1, 639, 641 and 3 bytes give whole 320-sample frames and keep the odd byte.
- Talk boundaries: packets every 30 ms for 1 s, a 2 s gap, packets again → two Talks; with `idleTimeout` × `timeScale`.
- Mute during a Talk ends it; a stop finishes `frames` and the handler's task ends.
- Encoders against 8.1–8.3.

## 8. Test vectors (computed by the spec writer)

### 8.1 G.711 (checked against FFmpeg `pcm_alaw` / `pcm_mulaw`)

| Sample | 0 | 1 | −1 | 1000 | −1000 | 8000 | −8000 | 32767 | −32768 |
|---|---|---|---|---|---|---|---|---|---|
| A-law | `d5` | `d5` | `55` | `fa` | `7a` | `8a` | `0a` | `aa` | `2a` |
| µ-law | `ff` | `ff` | `7e` | `ce` | `4e` | `a0` | `20` | `80` | `00` |

### 8.2 IMA ADPCM block (checked by decoding with FFmpeg's `adpcm_ima_wav`, byte-identical)

Input: 2050 samples of `round(8000 × sin(2π × 1000 × i / 16000))`, i = 0…2049 (a 1 kHz tone at 16 kHz). Two blocks of
516 bytes (1025 samples each), the first starting at index 0:

- Block 1, first 24 bytes: `00 00 00 00 77 77 77 e7 bc 99 21 35 34 02 b8 dc ab 8a 20 45 23 02 b8 dc`;
  last 8 bytes: `23 02 b8 dc ab 8a 30 54`.
- Block 2, first 12 bytes: `f5 0b 41 00 22 80 ca bc bb 18 52 34` (predictor 3061 = the input sample 1025, index 65);
  the index after block 2 is 63.
- Decoding block 1 gives `0, 11, 41, 104, 240, 533, …` (index 0 makes the first samples converge slowly).

A WAV wrapper for FFmpeg's check: format tag `0x0011`, 1 channel, 16000 Hz, block align 516, 4 bits per sample,
`cbSize` 2 with 1025 samples per block.

### 8.3 SDP (key and salt = bytes `00 01 … 1d`)

Controller `192.168.1.20`, loopback RTP port 50002, payload type 110 →
`a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwd` and `m=audio 50002 RTP/AVP 110`,
the rest as 3.1.

### 8.4 RTP (before SRTP encryption)

A return packet with payload type 110, sequence 1, timestamp 480, SSRC `0x00abcdef`: header
`80 6e 00 01 00 00 01 e0 00 ab cd ef`, then the AU header section for one 120-byte access unit `00 10 03 c0`, then the
120 bytes. The demuxer classes it as RTP (`0x6e` = 110 ≥ 90); an RTCP receiver report (`80 c9 …`, 201) as RTCP.

### 8.5 Framing

At 16 kHz/20 ms, 1000 bytes of stdout give one frame (640 bytes) and keep 360; 280 more bytes complete the second frame.
At 8 kHz/20 ms a frame is 320 bytes.

## 9. Open questions / unknowns

- **Opus return audio.** When a camera offers Opus, HomeKit may select it; the RTP clock and SDP (`opus/48000/2` per
  RFC 7587, or HomeKit's 16/24 kHz) used by HomeKit for the return direction were not established here. Hence the
  rule: two-way cameras offer AAC-ELD 16 kHz only.
- **Silence**: that HomeKit keeps sending packets while the talk button is held in silence (rather than stopping) is
  inferred from the existing code's behaviour, not measured. If it stops, a Talk ends after `idleTimeout` and a new one
  begins on the next word; cameras then reopen their channel, which costs latency (Reolink ~100 ms, Dahua a new HTTP
  request). Measure on a device and raise `idleTimeout` if needed.
- **Latency of FFmpeg's RTP input** (its jitter buffer and probing) was not measured; `-analyzeduration 0 -probesize 32`
  before `-i` may cut the start-up delay, but whether FFmpeg still finds the AAC-ELD parameters with them was not tested.
- Whether HomeKit sends comfort-noise packets (`comfortPT`) on the return direction with AAC-ELD is unknown.
- The receiver uses the controller's key for both directions because the existing streamers answer with it; a streamer
  that generated its own key would have to use the controller's key in this SDP anyway (HomeKit encrypts with its own).
