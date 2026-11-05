# Reolink: two-way talk over Baichuan (clean room)

## 0. Provenance

Written by the spec writer as a supplement to `Reolink.md` (whose addendum §A found that reolink-aio only *detects*
talk). It contains **no source code**. Baichuan message ids, header bytes, XML element names, the small XML bodies the
camera expects and the binary frame layout are given exactly because they are the wire interface. **Recommendation**
marks the spec writer's choices. Test vectors (section 9) were computed by the spec writer; two lengths were checked
against the official client's messages recorded in neolink's protocol notes (9.2).

| Id | Source | What was taken | Version / commit | Licence |
|---|---|---|---|---|
| N | neolink, https://github.com/QuantumEntangledAndy/neolink: `crates/core/src/bc_protocol/talk.rs`, `bc/xml.rs` (`TalkAbility`, `TalkConfig`, `Extension`), `bc/model.rs` (message ids), `bcmedia/{model,ser,de}.rs` (the ADPCM media frame), `src/talk/` (how a talk config is chosen, the GStreamer encoder settings), `dissector/messages.md` and `dissector/mediapacket.md` (recorded official-client messages) | Message ids 10, 11, 201, 202; the TalkConfig body; the ADPCM block layout; pacing; the 422 retry | commit `6e05e7844b5b50f89787d30bffcbbd3471bfcfde` (2025-01-30) | **AGPL-3.0** (neolink authors). Nothing is ported: this document describes the protocol only |
| R | reolink-aio, as `Reolink.md` §0 | capability detection (cmd 199, cmd 10 reply test), `talkAndReplyVolume` | `0.22.0`, commit `2da8b6bdba09e755f1167f32b146c18bd872b050` | MIT, `Copyright (c) 2023 starkillerOG` |
| G | go2rtc, as `ImouTalk.md` §0 | that Reolink's RTSP server offers a `PCMA/8000` `sendonly` backchannel track, and that a Reolink doorbell needed zero RTP timestamps | commit `990f4de3cc21d1cca917d02d0bc40f2fabe75a49` | MIT, `Copyright (c) 2022 Alexey Khit` |
| — | `ReturnAudio.md` | the PCM source and the IMA ADPCM encoder (§5.3) | this repository | the project's own |

neolink is AGPL: the implementer must not see it, and nothing in this document is its code. THIRD-PARTY-NOTICES: no
code is ported, so nothing is required; do not list neolink as a source of code.

## 1. Scope

Talk from HomeKit to a Reolink camera, doorbell, or NVR/Home Hub channel, over the plugin's existing Baichuan TCP
session (`Reolink.md` §5; `BaichuanSession`), AES-encrypted after login. Standalone battery cameras are covered by
`ReolinkBattery.md`; talk over their session works the same once connected.

## 2. Capability

1. Ask the talk ability only when `Reolink.md` addendum A.2's condition holds (HTTP `abilityChn[ch].talk.ver > 0`, or
   Baichuan `ipcAudioTalk > 0` for the channel, or a non-NVR's host `audioTalk > 0`).
2. Send `cmd_id` **10** (TalkAbility) on the channel: channel extension, no body (as A.2). Reply XML:

   | Element (under `body/TalkAbility`) | Meaning |
   |---|---|
   | `duplexList/duplex` (one or more) | `FDX` full duplex, `HDX` half duplex |
   | `audioStreamModeList/audioStreamMode` (one or more) | `followVideoStream`, `mixAudioStream` |
   | `audioConfigList/audioConfig` (one or more) | `priority` (integer), `audioType` (`adpcm`), `sampleRate` (e.g. `16000`), `samplePrecision` (`16`), `lengthPerEncoder` (e.g. `1024`), `soundTrack` (`mono`) |

3. Supported (reolink-aio's rule, A.2): any `audioStreamMode` = `mixAudioStream`, or `followVideoStream` together with
   `duplex` = `FDX`. **Additionally** (Recommendation) require an `audioConfig` whose `audioType` is `adpcm`,
   `soundTrack` `mono`, `samplePrecision` `16`, `sampleRate` 8000 or 16000 and `lengthPerEncoder` even and between 64
   and 4096: that is the only format specified here. Otherwise: no two-way audio (log once at info, with the values).
4. The chosen **talk config** = the first `duplex`, the first `audioStreamMode`, and the first suitable `audioConfig`
   (neolink copies the first of each; only one of each has been seen).
5. A reply with a status other than 200, or no `TalkAbility` element → not supported.

Run at start-up per channel; cache for the session. The camera is published with `twoWayAudio: true` only when
supported (the Speaker service, `ReturnAudio.md` §2.1).

## 3. Messages

All on the logged-in session, AES (`Reolink.md` §5.2), class `1464`, 24-byte header, `ch_id` = channel + 1 (as every
channel command of the session; neolink puts the bare channel number there and both appear to be accepted, §10), the
**channel extension** (`Reolink.md` §5.3.3) unless said otherwise.

| `cmd_id` | Name | Body | Reply |
|---|---|---|---|
| 10 | TalkAbility | none | 2 |
| 201 | TalkConfig (start) | the XML of 3.1 | 200, empty; **422** when a talk is already open (another client, or a talk we never stopped) |
| 202 | Talk (audio) | the **binary extension** of 3.2, then binary ADPCM frames (section 4) | 200 per message |
| 11 | TalkReset (stop) | none | 200 |

### 3.1 TalkConfig body

UTF-8, lines ending in a single `\n`, the values from the chosen talk config, `channelId` 0-based:

```
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<TalkConfig version="1.1">
<channelId>{channel}</channelId>
<duplex>{duplex}</duplex>
<audioStreamMode>{audioStreamMode}</audioStreamMode>
<audioConfig>
<audioType>adpcm</audioType>
<sampleRate>{sampleRate}</sampleRate>
<samplePrecision>16</samplePrecision>
<lengthPerEncoder>{lengthPerEncoder}</lengthPerEncoder>
<soundTrack>mono</soundTrack>
</audioConfig>
</TalkConfig>
</body>
```

No `priority` element (the official client sends none; it is only in the ability). With channel 0, FDX,
followVideoStream, 16000, 1024 this body is **394 bytes**, the same length as the official client's recorded message.

### 3.2 Binary extension (for 202)

```
<?xml version="1.0" encoding="UTF-8" ?>
<Extension version="1.1">
<binaryData>1</binaryData>
<channelId>{channel}</channelId>
</Extension>
```

(131 bytes for channel 0, again the official client's length.) Header bytes 20–23 = the extension's length; bytes 8–11
= extension length + binary length. The extension is AES-encrypted (fresh IV, as any piece); **the binary part is sent
in clear** (neolink sends it unencrypted with the session in AES mode, and the official client's recorded message
matches). Whether a session in "full AES" mode (`ReolinkBattery.md` §4.4) needs the binary encrypted with an
`encryptLen` is not known (§10).

### 3.3 Message numbers

All 202 messages of one Talk carry the **same** message number (neolink subscribes once per Talk and sends every audio
message on it). In Homeswift's header (bytes 13–15 the 24-bit counter), take one counter value at the start of the Talk
and reuse it for each 202 of that Talk. Each 202 is answered with that full message id; since only one request may be
pending per (`cmd_id`, full message id) (`Reolink.md` §5.3.3), send the next 202 only after the previous reply came
(neolink's live path does exactly this). 201 and 11 take ordinary new counter values.

## 4. ADPCM frames (the binary of 202)

### 4.1 Block

IMA ADPCM, DVI-4 layout, mono (`ReturnAudio.md` §5.3): a 4-byte header (int16 LE first sample, step index, 0) then
4-bit codes, low nibble first. Sizes from the talk config:

| | Formula | `lengthPerEncoder` 1024 |
|---|---|---|
| code bytes per block | `lengthPerEncoder / 2` | 512 |
| block bytes (`B`) | code bytes + 4 | 516 |
| samples per block | `lengthPerEncoder + 1` | 1025 (64.06 ms at 16 kHz) |

The GStreamer pipeline neolink uses encodes with "block align" = `B` in DVI layout, i.e. this format.

### 4.2 Media frame around a block

Each block travels in a BcMedia ADPCM frame (the same framing the camera uses for its own ADPCM audio,
`ReolinkBattery.md` §5), all little-endian:

| Offset | Size | Value |
|---|---|---|
| 0 | 4 | magic, ASCII `01wb` (`30 31 77 62`) |
| 4 | 2 | payload size `P` = `B` + 4 |
| 6 | 2 | `P` again |
| 8 | 2 | `00 01` (the uint16 0x0100, a sub-magic; the camera's own frames may carry `00 7a`) |
| 10 | 2 | `(B − 4) / 2` (256 for B = 516; some cameras put 2 here in their own frames) |
| 12 | `B` | the block |
| 12 + `B` | 0–7 | zero padding so that `P` is a multiple of 8 |

With `B` = 516: `P` = 520, no padding, **528 bytes** per frame. (neolink's encoder pads by the block's length instead
of `P` and so appends 4 zero bytes, 532 per frame; cameras accept that too, but the official client's recorded message
is 4 × 528 bytes. Use 528.)

### 4.3 Frames per message

The official client sends **4 frames per 202** (2112 bytes of binary, 256 ms of audio at 16 kHz); neolink's live path
sends 1 frame per message. **Recommendation:** 1 frame per message for latency (64 ms per message instead of 256 ms),
falling back to 4 if a camera answers 202 with an error. Never split a frame across messages.

## 5. Sequence and pacing

1. Talk begins (`ReturnAudio.md` §4, `ReturnAudioFormat(sampleRate: {sampleRate}, frameDuration: 20 ms)`).
2. Send 201. On 422: send 11, wait for its reply, send the same 201 again (once). On 200 continue; any other status or no
   reply in 5 s → log "the camera refused the talk format" (with the config values) and end (the handler returns).
3. Collect PCM samples; every time 1025 (samples per block) are available, encode a block (the step index carried from
   the previous block, starting at 0 for the Talk), frame it (4.2), send a 202, await its reply (timeout 2 s). Frames
   come in real time, so pacing is the source's: about one 202 every 64 ms.
4. Queue limit: if more than 3 blocks (≈ 190 ms) are waiting because replies are slow, drop the oldest blocks (keep the
   step index as encoded; the next block header resynchronises the decoder).
5. A 202 reply with a status other than 200, or a timeout: end the Talk (send 11).
6. When `frames` finishes: pad the last partial block with zeros, send it, then wait until the audio sent has played
   (track an "expected end" time: each block adds samples/sampleRate seconds, starting from the later of now and the
   previous expected end), **plus 100 ms**, then send 11. Sending 11 earlier cuts the last words (neolink's timing).
7. If the session drops during a Talk, the Talk ends without 11 (the next 201 gets 422 and the retry of step 2 clears it).

Latency budget at 16 kHz: block filling 64 ms + one message ≈ 70–100 ms on the LAN, plus FFmpeg's decoding.

## 6. Other paths

- **RTSP backchannel.** Reolink's RTSP server (session name `BC Streaming Media`) describes a third audio section
  `m=audio 0 RTP/AVP 8`, `a=rtpmap:8 PCMA/8000`, `a=sendonly` on some models [G], usable with the client of
  `ImouTalk.md` §4 (G.711 A-law, 1024-byte packets, and on a Reolink doorbell **zero RTP timestamps** [G]). Not
  recommended: it needs the RTSP stack and is not available on battery cameras. Keep as a documented fallback only.
- **HTTP API**: none documented for talk (`Reolink.md` A.1).

## 7. Volume and interplay

- The speaker volume for talk is the camera's `talkAndReplyVolume` (`GetAudioCfg`/`SetAudioCfg`, Baichuan `cmd_id`
  264 `audioCfg`). Do not write it from HomeKit's Speaker Volume (`ReturnAudio.md` §5.5): scale samples instead, never
  above 100 %.
- A siren or quick-reply message played during a Talk: behaviour unknown (§10); **Recommendation:** do not start the
  siren from HomeKit while a Talk is open on that channel (wait for the Talk to end).
- Battery cameras behind a Home Hub: a Talk wakes the camera; the first 201 may get status 400 (waking): wait 1.5 s and
  send it again, up to 3 times (reolink-aio's 400 rule, `Reolink.md` §5.1).

## 8. Implementation notes for Homeswift (Recommendation)

- `BaichuanSession` gains a request that carries a binary payload after an extension (extension encrypted, binary in
  clear, the header's extension length set) and a way to fix the counter for a series of requests (3.3).
- A status of 422 must be returned to the caller, not only thrown as `status(422)`, so that step 2 can tell it apart.
- `ReolinkStreamer` uses the shared `ReturnAudioReceiver` (`ReturnAudio.md` §4.1) on its audio return port.
- `ReolinkTalk` (one per channel): holds the cached talk config and runs section 5 as the receiver's handler; one Talk
  at a time per channel (a second waits for the first's 11).

## 9. Test vectors (computed by the spec writer)

### 9.1 Headers (channel 0 → `ch_id` 1; counters arbitrary)

| Message | Bytes |
|---|---|
| 10 TalkAbility (counter 0x14, extension 104 bytes) | `f0 de bc 0a 0a 00 00 00 68 00 00 00 01 14 00 00 00 00 14 64 68 00 00 00` |
| 201 TalkConfig (counter 0x15, 104 + 394 = 498 bytes) | `f0 de bc 0a c9 00 00 00 f2 01 00 00 01 15 00 00 00 00 14 64 68 00 00 00` |
| 201 reply 422 | `f0 de bc 0a c9 00 00 00 00 00 00 00 01 15 00 00 a6 01 14 64 00 00 00 00` |
| 202 one frame (counter 0x16, 131 + 528 = 659 bytes) | `f0 de bc 0a ca 00 00 00 93 02 00 00 01 16 00 00 00 00 14 64 83 00 00 00` |
| 202 four frames (131 + 2112 = 2243 bytes) | `f0 de bc 0a ca 00 00 00 c3 08 00 00 01 16 00 00 00 00 14 64 83 00 00 00` |
| 11 TalkReset (counter 0x17) | `f0 de bc 0a 0b 00 00 00 68 00 00 00 01 17 00 00 00 00 14 64 68 00 00 00` |

The channel extension of `Reolink.md` §5.3.3 (as `Baichuan.channelExtension` writes it, trailing newline, no leading
one) is 104 bytes; with AES-CFB the encrypted lengths equal the plaintext lengths.

### 9.2 Lengths checked against recorded official-client messages

TalkConfig message length 498 (`0x1f2`) with extension 104 (`0x68`); Talk message length 2243 (`0x8c3`) with extension
131 (`0x83`), i.e. 4 frames of 528 bytes. Both match the bodies of 3.1, 3.2 and the frame of 4.2 exactly.

### 9.3 Media frame

The block of `ReturnAudio.md` §8.2 (block 1, 516 bytes) framed: `30 31 77 62 08 02 08 02 00 01 00 01` followed by
`00 00 00 00 77 77 77 e7 bc 99 …` (the 516 block bytes); 528 bytes in all, no padding.

For a hypothetical `lengthPerEncoder` 512 (B = 260, P = 264): header `30 31 77 62 08 01 08 01 00 01 80 00`, 260 block
bytes, no padding (264 = 33 × 8); 272 bytes. For B = 258 (`lengthPerEncoder` 508): header `30 31 77 62 06 01 06 01
00 01 7f 00`, P = 262, 2 padding bytes, 272 bytes.

### 9.4 TalkAbility reply fixture (shape of a recorded reply, values as seen)

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<body>
<TalkAbility version="1.1">
<duplexList><duplex>FDX</duplex></duplexList>
<audioStreamModeList><audioStreamMode>followVideoStream</audioStreamMode></audioStreamModeList>
<audioConfigList><audioConfig><priority>0</priority><audioType>adpcm</audioType><sampleRate>16000</sampleRate>
<samplePrecision>16</samplePrecision><lengthPerEncoder>1024</lengthPerEncoder><soundTrack>mono</soundTrack></audioConfig></audioConfigList>
</TalkAbility>
</body>
```

→ supported; talk config FDX / followVideoStream / 16000 / 1024; PCM asked at 16 kHz; blocks of 516 bytes. Variants:
`<duplex>HDX</duplex>` with `followVideoStream` → not supported; `<audioType>aac</audioType>` → not supported here.

### 9.5 Pacing

A 1.0 s Talk at 16 kHz = 16000 samples → 15 full blocks (15 375 samples) + one zero-padded block: 16 messages of 202;
expected playback end ≈ 16 × 64.06 ms = 1.025 s after the first block was sent; 11 sent ≈ 100 ms after that.

## 10. Open questions / unknowns

- **`ch_id`**: neolink sends the bare channel number in header byte 12 for talk messages (0 on a camera), reolink-aio
  and Homeswift use channel + 1 for channel commands (cmd 10 works that way). Whether 201/202/11 accept channel + 1 has
  not been verified on a device; if a camera answers 201 with an error, retry with the bare channel number before giving
  up.
- **NVR / Home Hub channels**: whether a hub relays Baichuan talk to a channel's camera (TalkConfig `channelId` > 0) is
  not shown by the sources; reolink-aio's capability rule suggests it does for `ipcAudioTalk` channels.
- **Formats other than ADPCM** (`audioType` `aac`?) and sample rates other than 16000 have not been seen.
- **Full-AES sessions**: whether the 202 binary must then be encrypted (with `encryptLen` in the extension) is unknown;
  the recorded messages and neolink send it in clear.
- **202 replies**: whether the official client waits for each reply, or the camera tolerates several outstanding 202s
  on one message number, is not recorded.
- **Siren or chime during a Talk**, and whether a Talk silences the doorbell's own chime, are unknown.
- The block-size field at offset 10 is 2 on some cameras' own frames; whether a camera checks it on received frames is
  unknown (send `(B − 4) / 2`).
