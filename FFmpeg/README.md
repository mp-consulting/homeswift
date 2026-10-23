# ffmpeg-for-homeswift

A static FFmpeg for Homeswift's camera plugins, in the spirit of Homebridge's
[ffmpeg-for-homebridge](https://github.com/homebridge/ffmpeg-for-homebridge): one binary per architecture that
runs on any Linux (musl, every library linked in), with what HomeKit cameras need and little else. The bridge's
container image (`../Dockerfile`) copies it from `ghcr.io/mp-consulting/ffmpeg-for-homeswift`.

| Part | Version | Licence | For |
|---|---|---|---|
| FFmpeg | 8.1.3 | GPLv3 (`--enable-gpl --enable-version3`) | SRTP, RTSP and RTSPS, fMP4, the native AAC-LC encoder and AAC-ELD decoder |
| x264 | head of `stable` | GPLv2 or later | Software H.264 encoding |
| Opus | 1.5.2 | BSD | Live stream audio and two-way audio |
| OpenSSL | 3.5 LTS | Apache 2.0 | TLS for `rtsps://` |

Hardware encoding: `h264_v4l2m2m` (Raspberry Pi). VAAPI and Quick Sync load their drivers at run time, which a
static binary cannot do, so Intel machines encode with libx264.

## Why not ffmpeg-for-homebridge

ffmpeg-for-homebridge has `libfdk_aac` for AAC-ELD, HomeKit's usual live stream audio. FFmpeg only combines
fdk-aac with GPL code (x264) under `--enable-nonfree`, which makes the binary not redistributable. This build
leaves fdk-aac out and stays redistributable:

- **Live streams** send Opus, which HomeKit also accepts. The UniFi Protect plugin offers Opus when FFmpeg has
  libopus and no AAC-ELD encoder (`ProtectStream.liveAudioCodec`); with libfdk_aac or macOS's `aac_at` it offers
  AAC-ELD, as the Homebridge plugin does.
- **HKSV recordings** are AAC-LC, which FFmpeg encodes natively.
- **Two-way audio** decodes the Home app's Opus and sends the camera AAC-LC from FFmpeg's own encoder.

## Building

```bash
docker build -t ghcr.io/mp-consulting/ffmpeg-for-homeswift:8.1.3-1 FFmpeg
```

The image is `FROM scratch`: `/ffmpeg`, `/licenses` (each part's licence and a README.txt) and `/sources` (the
tarballs it was built from, which the GPL asks to keep with the binary). To take the binary out:

```bash
docker create --name ffmpeg ghcr.io/mp-consulting/ffmpeg-for-homeswift:8.1.3-1 /ffmpeg && docker cp ffmpeg:/ffmpeg . && docker rm ffmpeg
```

## Releasing

`.github/workflows/ffmpeg.yml` builds amd64 and arm64 on native runners when `FFmpeg/` changes on main, and pushes
`<FFMPEG_VERSION>-<REVISION>` and `latest`. It refuses a tag that exists: bump `REVISION` in the Dockerfile for a
changed build, or set a new `FFMPEG_VERSION` (and its checksum) with `REVISION=1`. Then point `FFMPEG_IMAGE` in
`../Dockerfile` at the new tag. A new GHCR package is private until its visibility is set to public.
