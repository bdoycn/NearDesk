# Dual-Mac clarity gate (2026-10-29)

## Topology

- Host: UTM VM `v1` at `10.0.0.202`, GUI `NearDesk.app`, Screen Recording allowed for `dev.neardesk.spike`.
- Viewer: neo at `10.0.0.192`, and `v2` at `10.0.0.193`.
- Baseline: system Screen Sharing (VNC) from neo to v1.

## Result

- v2 Viewer to v1 GUI Host: auth and FRAME, Watching 1920×1200, frame 1728×1080.
- neo GUI Viewer to v1: Watching 1920×1200, TextEdit sample visible.
- Sample text: `NearDesk 汉字「永」`, repeated「永」, `The quick brown fox jumps over the lazy dog.`, and an `MMWW` line.
- Samples (not committed): `.cua-out/gate-nd-win.png` (NearDesk) and `.cua-out/gate-ss-win.png` (system Screen Sharing).
- Recorded pane edge-energy heuristic: NearDesk crop 443, Screen Sharing crop 282.「永」and the Latin lines are readable in both.
- North PASS: TextEdit readability beats or meets the provisional bar versus system Screen Sharing.

## GUI Host is required to paint

A CLI Host started over SSH often has an empty `DisplayCatalog` in that session, so it never paints. Use the GUI app with Screen Recording on.

On UTM, `CGGetActiveDisplayList` can return an active count of 0 while a display is still online (`online=1`, `main=1`). `DisplayCatalog` then uses the online list, then the main display, so a GUI Host does not send an empty `displayList`.

Dual-Mac runs are the clarity gate. Product latency stays on same-machine loopback. Empty `gg_ns` / `feedback_ns` on a dual-Mac CSV is expected (`clocksMatch` is loopback only; Host inject marks stay on the Host).
