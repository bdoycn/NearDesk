# NearDesk

Open-source **Mac ↔ Mac** local-network screen sharing for everyday desk collaboration.

NearDesk focuses on low-friction LAN sessions between Macs—discover a nearby machine, share a desktop session, and work together without routing traffic through a cloud relay by default.

> **Not the same project as other “NearDesk” repos.**  
> If you found a different GitHub project also named NearDesk / neardesk (for example a Windows LAN RDP / AI-worker toolkit), that is unrelated and not maintained here. This repository is the NearDesk **Mac ↔ Mac** screen-sharing client.

## Status

Early spike. APIs, UX, and packaging will change. Issues and PRs are welcome once contribution docs below feel clear enough to follow.

## macOS spike

One SwiftUI app, two modes (Host and Viewer). The wire format is [docs/spike-protocol.md](docs/spike-protocol.md): Bonjour `_neardesk._udp`, QUIC with ALPN `neardesk-spike/1`, then control / video / input streams. M1 sends a full HEVC frame (H.264 if HEVC will not start) and puts ScreenCaptureKit dirty rects in the frame header. There is no tile channel, WebRTC, or public relay.

### Run

```sh
swift test
Scripts/package-app.sh
open .build/NearDesk.app
```

`swift test` checks the codec, Annex-B conversion, latency CSV join, a VideoToolbox keyframe, and a loopback QUIC login plus video stream. Screen Recording is not required for those tests.

In the app:

1. Host: set a password (1–128 UTF-8 bytes) and choose **Start sharing**. The password is sent only on the control stream after QUIC. Bonjour TXT is `ver=1` and the display name.
2. Viewer on the same Mac: enter that password and choose **Connect to this Mac**. The first time, trust the certificate SHA-256. A mismatch does not send the password; use **Forget saved fingerprint**, then connect again.
3. Viewer on another Mac on the LAN: pick the Host in the list. That path needs Local Network permission.
4. Click the picture to control the desktop. **Esc** releases the pointer on this Mac and is not forwarded.

The measured picture is aspect-fit inside 1920×1080 at 60 fps, 4:2:0. Compare text in TextEdit with the system screen-sharing app; M1 cannot do 4:4:4, and a shortfall there is left for a later tile pass.

### Permissions

| Mode | Permission | If it is off |
| --- | --- | --- |
| Host | Screen Recording | Sharing does not start a stand-in picture |
| Host | Accessibility | Key and pointer injection fails and the status says so |
| Host and Viewer | Local Network | Discovery or the connection fails with a Local Network message |

The packaged app’s bundle id is `dev.neardesk.spike`. Ad-hoc signing changes every rebuild, so macOS may ask again. Allow NearDesk in System Settings → Privacy & Security.

### Latency

HUD in the Viewer shows rolling glass-to-glass (T4 present − T0 capture) p50/p95 and input-feedback (T4 − T_inject) p50. **Connect to this Mac** is the path that fills those numbers: both sides use `mach_continuous_time` on one machine. A Bonjour session to another Mac still writes the timestamp columns, but `gg_ns` and `feedback_ns` are left empty because the clocks differ.

CSV files (truncated when a viewer session starts):

`~/Library/Application Support/NearDesk/spike/latency-video.csv`

```text
frame_id,channel_id,encoder_config_id,dirty_rect_count,au_bytes,t0_capture_ns,t1_encode_done_ns,t2_send_ns,t3_recv_ns,t4_present_ns,gg_ns
```

`~/Library/Application Support/NearDesk/spike/latency-input.csv`

```text
event_id,kind,display_id,event_mono_ns,t_inject_ns,t4_present_ns,feedback_ns,e2e_ns,matched_frame_id
```

`kind` is `mouse_move`, `mouse_button`, `wheel`, or `key`. Input feedback matches the first presented frame whose capture time is at or after `CGEventPost` and that has dirty rects or `DIRTY_NONE`. `e2e_ns` is T4 minus the viewer’s local event time; it is not the pinned number. Targets on loopback: video p50 ≤ 40 ms and p95 ≤ 80 ms, input feedback p50 ≤ 50 ms. **Show latency CSV** reveals the files. The password is not written to the HUD, the CSV, or Bonjour.

## What this is / isn’t

| This project | Not this project |
| --- | --- |
| Mac ↔ Mac over the local network | Cloud-first remote desktop as the default path |
| Open-source client under Apache-2.0 | A Windows RDP control panel for AI coding workers |
| Product brand: **NearDesk** | Apple’s system “Screen Sharing” / “屏幕共享” product naming in UI copy |

We avoid using Apple’s system product name as our primary UI label so NearDesk stays visually and verbally distinct.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please open an issue before large changes.
