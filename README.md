# Moonlight PC — Wireless QoL Fork

A fork of [moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) (v6.1.0) focused on making streaming over Wi-Fi more reliable and less annoying to manage.

---

## What's different

### Configurable audio jitter buffer

The original client drops decoded audio frames whenever more than 30 ms of audio is queued in the pre-decode buffer. On a congested or variable-latency wireless connection this fires constantly, producing crackling and micro-stuttering that is unrelated to the video pipeline.

This fork adds an **Audio Jitter Buffer** slider in **Settings → Audio Settings** that lets you raise that threshold:

| Value | Effect |
|---|---|
| **30 ms** (default) | Original behaviour — most aggressive drop threshold |
| **60–80 ms** | Good starting point for most Wi-Fi connections |
| **100–120 ms** | For high-jitter or congested networks |

Raising the slider allows more packets to queue during a burst before any are dropped, giving the decoder time to work through the backlog without punching holes in the audio stream. A small amount of additional audio latency is introduced equal to the extra buffer. Video is unaffected — A/V sync is maintained by the underlying stream.

**The change takes effect the next time you start a stream.**

### AWDL suppression

AirDrop, Handoff, and Sidecar all use Apple Wireless Direct Link (AWDL), a peer-to-peer Wi-Fi mode that competes with infrastructure traffic. On congested networks it can cause periodic bursts of packet loss during a stream.

This fork can suppress AWDL for the duration of a stream:

- **Auto-suppress** on stream start (opt-in toggle in **Settings → Advanced Settings**)
- **Keyboard shortcut** Ctrl+Alt+Shift+A to toggle mid-stream, with a 5-second overlay confirmation
- Implemented as a bundled privileged LaunchDaemon (registered via SMAppService — one-time system authorization prompt, never asks again)
- The helper monitors `awdl0` via an `AF_ROUTE` socket and forces the interface back down if macOS tries to re-raise it
- Automatically tears itself down and restores AWDL when Moonlight exits or crashes

---

## Coming next

### Adaptive auto-tuning jitter buffer

Rather than requiring manual tuning, the buffer will tune itself automatically:

- Observes rolling 3-second peaks in pre-decode queue depth
- Uses an EMA to smoothly scale back the buffer when the connection calms down
- Runs a shadow "probe" slightly ahead of the main buffer to catch spikes early before they cause drops
- The stats overlay (Ctrl+Alt+Shift+S) will show the live buffer value and a rolling 15-minute overflow counter

---

## Downloads

macOS (Apple Silicon) builds are available on the [Releases](../../releases) page.

> **First launch:** macOS will say the app is "damaged" because this build is not signed with an Apple Developer certificate. To open it, run once in Terminal:
> ```
> xattr -dr com.apple.quarantine /Applications/Moonlight.app
> ```

For other platforms or unmodified builds, use the official [moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt/releases) releases.

---

## Building (macOS)

**Requirements:** Qt 6.7+, Xcode 14+

```bash
git submodule update --init --recursive
python3 setup-deps.py
qmake moonlight-qt.pro QMAKE_APPLE_DEVICE_ARCHS=arm64
make -j$(sysctl -n hw.logicalcpu) release
```

For a distributable DMG, run `./dev-dmg.sh` from the repo root. It does an incremental build, compiles and bundles the AWDL helper binary, and drops a signed DMG on your Desktop.

See the [upstream README](https://github.com/moonlight-stream/moonlight-qt) for Windows, Linux, and Steam Link build instructions.

---

## Credits

**Upstream project**
[moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) — the open source NVIDIA GameStream / Sunshine client this fork is based on. All core streaming, decoding, input, and UI code is from that project.

**AWDL suppression**
The AWDL monitoring and suppression technique (AF_ROUTE socket watcher + `ioctl(SIOCSIFFLAGS)`) is based on [AWDLControl](https://github.com/seemoo-lab/AWDLControl) by the Secure Mobile Networking Lab (SEEMOO) at TU Darmstadt, released under GPLv3.

**Moonlight ecosystem**
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) — open source GameStream host (required for non-NVIDIA hosts)
- [moonlight-stream/moonlight-android](https://github.com/moonlight-stream/moonlight-android) and [moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) — mobile counterparts
