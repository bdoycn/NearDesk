# QUIC `extract` on UTM (2026-10-29)

`NWConnectionGroup.extract` opened the Viewer control stream with a fresh empty `NWProtocolQUIC.Options()`. On UTM that stream failed immediately with `ENETDOWN` (POSIX 50), before `writePreface`. Turning off `includePeerToPeer` did not help.

`NWConnectionGroup.extract(connectionTo:using:)` takes `NWProtocolOptions?`. Pass `using: nil` so the child connection inherits the group's QUIC options (ALPN and TLS). Do not pass `NWProtocolQUIC.Options()`. Send-only pipes still set `receives` from the requested direction. If a later stream must change `direction`, copy the group's options and edit the copy.

Verified: neo loopback PASS; v1 Host to neo Viewer auth and FRAME PASS; v2 Viewer to v1 Host auth PASS.

## Latency CSV

`LatencyHub` fills `gg_ns` and `feedback_ns` only when the Viewer sets `clocksMatch`. That is true only for loopback, where both sides share `mach_continuous_time`. Dual-Mac rows leave those columns empty. Host `host-*-marks.csv` and Viewer `latency-*.csv` are written on each machine's Application Support directory and are not merged across machines.

Product latency is same-machine loopback only. Dual-Mac is clarity only. An empty dual-machine latency CSV is expected, not a failure.
