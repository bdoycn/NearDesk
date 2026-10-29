# NearDesk Spike Protocol

本文是本周 spike 的实现对齐说明。NearDesk 是面向局域网的 Mac 远程桌面：Host 采集本机画面并注入输入，Client 解码呈现并发送键鼠。

协议里的标识符、消息名、字段名保持英文，方便 Cocoa 代码直接对照。标有「产品已钉」的条目是本周口径，实现不要改定义。未标注的字节布局是 spike 草案：Host 与 Client 按此实现，测完再改。

## 产品已钉

### 延迟「产品已钉」

测量条件：LAN、1080p60、dirty-rect path。

- 视频 glass-to-glass：p50 ≤ 40ms，p95 ≤ 80ms。
- 键鼠：keyboard/mouse inject → remote visible feedback，p50 ≤ 50ms。

两个数分开报，不能用视频延迟代替输入反馈，也不能把编码耗时单独当成 glass-to-glass。

口径：

- **glass-to-glass** = `T4_present − T0_capture`。`T0` 是这一帧的采集时刻，`T4` 是 Client 把这一帧交给显示（view / layer present）的时刻，不是解码完成时刻。
- **input feedback** = `T4_present − T_inject`。`T_inject` 是 Host 调用 `CGEventPost` 的时刻；`T4` 是其后第一帧已经呈现、且该帧带有 dirty rect（或 `DIRTY_NONE` 的整帧）的时刻。
- 同机 loopback 允许，两边都用 `mach_continuous_time` 换算成纳秒，时钟相同。不要求外接摄像机。
- 条件里的 dirty-rect path 指 ScreenCaptureKit 交出 dirty rects，并且视频帧头带上这些矩形。M1 仍对采集画面做整帧 HEVC / H.264，不是按矩形裁剪编码。

### 仓库「产品已钉」

Public 仓库，许可证 Apache-2.0。Spike 不引入与 Apache-2.0 不兼容的依赖。许可证以仓库根目录的 [LICENSE](../LICENSE) 与 [NOTICE](../NOTICE) 为准；本文档不另行定义许可证。

### 本周范围「产品已钉」

只做三件事：**M1 媒体路径 + 输入注入 + 可度量延迟**。

M2（小脏区无损瓦片 + 大运动 HEVC）是后续切片，本周不实现、不联调、不作为成功条件。

### 传输「产品已钉」

传输用 **QUIC**。视频和输入走 **同一条 QUIC 连接上的不同 stream**。Spike 不用 WebRTC。

一条 stream 上视频帧的队头阻塞不得挡住输入。控制消息再单独用一条 stream，不塞进视频或输入。

### 成功标准「产品已钉」

在本机用 TextEdit 打字，经 NearDesk 看远端（或同机 loopback）画面时，文字清晰度要好于系统「屏幕共享 / Screen Sharing」。

这是画质门槛，和上面的延迟数字并列。M1 已知做不到真正的 4:4:4；本周仍以这条目视对比作为是否过关的标准，不把 M2 提前拉进来凑清晰度。

## Spike 架构

### 1. 网络与发现

默认路径是 LAN。同一私网或 VPN 上的直连可以。本周不为公网中继排优先级，不接第三方 relay。

发现用 Bonjour / Network.framework：

- Host：`NWListener`（QUIC）并发布服务。
- Client：`NWBrowser` 浏览后，用户点选再连接。
- 服务类型（暂定）：`_neardesk._udp`。`_neardesk` 长度符合 Bonjour 服务名限制；QUIC 在 UDP 上，协议后缀用 `_udp`。
- TXT 只放非秘密信息，例如 `ver=1` 和显示名。密码不进 Bonjour。

发现完成之后做 **password login**。口令只在 QUIC/TLS 握手完成之后、在 control stream 里发送。

建议连接顺序：

1. Client 解析到 Host 的 UDP 地址，发起 QUIC。
2. TLS 1.3 握手完成，Client 做 TOFU 指纹确认。
3. Client 打开 control stream，发送 `HELLO`、`AUTH_PASSWORD`。
4. Host 回复 `AUTH_RESULT`，成功后再发 `DISPLAY_LIST`。
5. Client 发送 `SELECT_DISPLAY`。
6. Host 打开 video stream 并开始采集；Client 打开 input stream。两条 stream 互不等待对方的帧。

ALPN（草案）：`neardesk-spike/1`。

### 2. 媒体 M1

路径：

`ScreenCaptureKit dirtyRects` → `VideoToolbox HEVC`（失败则 `H.264`）→ Client 解码 → present。

Host 用 `SCStream` 采集一块显示器。测量配置是 1920×1080、目标 60 fps（`minimumFrameInterval` 对应 1/60）。关闭音频。像素格式选 VideoToolbox 能少一次色彩转换就吃进去的格式；色度仍然是 4:2:0。

编码：

- 默认 `kCMVideoCodecType_HEVC`，`channel_id = hevc_main`。
- HEVC 会话建不起来再用 `kCMVideoCodecType_H264`，`channel_id = h264_fallback`。
- 关闭帧重排序（无 B 帧），打开 real-time，把允许的帧延迟压到最低。这些是为了摸延迟目标的实现手段，不是另一套产品口径。
- 每个访问单元用 Annex-B。参数集（HEVC 的 VPS/SPS/PPS，H.264 的 SPS/PPS）放在 `VIDEO_CONFIG`，关键帧里可以重复带。

**VideoToolbox 做不到真正的 4:4:4，也没有 ROI QP。** 不要在 M1 里寻找隐藏开关把文字区域单独抬质量。dirty rects 在 M1 的用途是：放进帧头、驱动延迟统计、告诉 Client 哪一块更新了。编码本身仍是整帧。

画面几何或参数集变化时递增 `encoder_config_id`，并先发新的 `VIDEO_CONFIG`，再发引用它的 `VIDEO_FRAME`。

#### M2 下一刀（M1 不发送）

M2 处理「文字要锐、拖窗口又不能靠无损撑带宽」：小脏区走 `lossless_tile`，大面积运动继续 HEVC，按脏区面积分流，而不是在 VideoToolbox 里调色度或 ROI。

组帧、面积阈值、合成顺序和延迟记账写在 [spike-m2-tiles.md](spike-m2-tiles.md)。North 2026-10-29 的验收和范围在那边标成产品已钉；阈值和字节布局仍是 spike 草案。M1 的成功条件仍以上面的产品已钉为准。

在 Host 按那份草案实现之前，不要发送 `channel_id = lossless_tile`。收到则忽略。

### 3. 输入

Host 用 `CGEventPost` 注入（`kCGHIDEventTap`）。事件来自 Client 的 input stream，与 video stream 分离，但是同一条 QUIC 连接。

每条输入都带：

- 绝对坐标（鼠标类）：目标显示器像素坐标，原点在该显示器左上角，y 向下。
- `display_id`：`CGDirectDisplayID`。
- 按键 / 按钮 / 滚轮，见下文消息。
- `event_mono_ns`：Client 在本地发生该输入时的 `mach_continuous_time` 纳秒。

Host 把像素换成 `CGEvent` 的全局 point：

```text
scale        = scale_num / scale_den          # 来自 DISPLAY_LIST
global_x_pt  = origin_x_pt + x_px / scale
global_y_pt  = origin_y_pt + y_px / scale
```

`display_id` 与当前选中的显示器不一致时，Host 丢弃并计数，不猜另一块屏。尚未 `SELECT_DISPLAY` 时同样丢弃。

键盘用 `CGKeyCode`（`kVK_*`）加 modifiers 位图。`utf32` 只供日志和对照，注入以 keycode 为准。

### 4. 加密

信任模型是 **LAN trust**。底线：路径上没有第三方 relay。数据只在已经选中的对端之间。

- 承载加密是 QUIC / TLS 1.3。没有明文帧；握手完成前不发任何应用消息。
- Spike 可以用自签证书。Client 展示叶子证书 DER 的 SHA-256 指纹，用户第一次接受后记住（TOFU）。再次连接指纹不符则断开，并且不要发送 `AUTH_PASSWORD`。
- 口令在 TLS 之内传输。Bonjour、TXT、日志、延迟 CSV 里都不写口令。

### 5. 延迟测量

视频时间戳：

| 记号 | 位置 | 含义 |
| --- | --- | --- |
| T0 | Host | 采集时刻，写入 `VIDEO_FRAME.capture_mono_ns` |
| T1 | Host | VideoToolbox 这一帧编码完成 |
| T2 | Host | 该帧字节交给 QUIC 发送 |
| T3 | Client | QUIC 把该帧交到应用 |
| T4 | Client | 该帧 present |

```text
Host                                      Client
SCStream callback   T0
VT encode done      T1
QUIC write          T2  ---------------->  T3  QUIC read
                                            T4  present
```

同机时 `gg_ns = T4 − T0`。分段只用于排查，不替代 GG：

- `T1 − T0` 编码
- `T2 − T1` 发送排队
- `T3 − T2` 在途（仅同机时钟有效）
- `T4 − T3` 接收到呈现

两台机器时钟不同。两机时仍记录分段；`gg_ns` 留空，除非另外有明确的时钟差。本周用同机 loopback 填「产品已钉」的 GG 读数即可。

输入：

```text
Client 本地键鼠     event_mono_ns          （补充列，不是钉死的起点）
       | input stream
Host   CGEventPost   T_inject
       | 随后被采集进某一帧
Client present       T4，匹配规则见「产品已钉」
feedback_ns = T4 − T_inject
```

视频 GG 和 input feedback 分开汇总。滚动窗口建议视频不少于 300 帧、输入不少于 100 次，再读 p50 / p95；窗口长度不是产品口径，但单次口头样本不能当结果。

可选：

- Client HUD：滚动显示 video GG 的 p50 / p95，以及 input feedback 的 p50。HUD 只为现场调参。
- CSV 是 spike 报告的依据。建议两个文件，按 `frame_id` / `event_id` 对齐。

`latency-video.csv`：

```text
frame_id,channel_id,encoder_config_id,dirty_rect_count,au_bytes,t0_capture_ns,t1_encode_done_ns,t2_send_ns,t3_recv_ns,t4_present_ns,gg_ns
```

`latency-input.csv`：

```text
event_id,kind,display_id,event_mono_ns,t_inject_ns,t4_present_ns,feedback_ns,e2e_ns,matched_frame_id
```

`feedback_ns` 对钉死的输入指标。`e2e_ns = T4 − event_mono_ns` 是用户手感的补充列，不替代 `feedback_ns`。

纳秒换算：

```text
mach_timebase_info(&tb)
ns = mach_continuous_time() * tb.numer / tb.denom
```

Host 与 Client 都用 `mach_continuous_time`，避免睡眠导致 `mach_absolute_time` 跳变。`capture_mono_ns` 用这个时钟；若 ScreenCaptureKit 的 PTS 与回调时刻不一致，以写入帧头的 `capture_mono_ns` 为准，PTS 只进调试日志。

### 6. 权限

Host：

- **Screen Recording**：ScreenCaptureKit。未授权则不要出假画面，直接失败。
- **Accessibility**：`CGEventPost`。未授权则输入路径失败，不要静默丢掉却报成功。
- **Local Network**：发布 Bonjour。

Client：

- **Local Network**：`NWBrowser` 发现 Host。
- 观看和发送输入不需要屏幕录制或辅助功能。

## Spike 交付物

本周交付这些，不多做：

1. **本文档** `docs/spike-protocol.md`。
2. **最小 Host 与 Client**。同机 loopback 算数：一边采集、编码、注入，另一边解码、呈现、发输入。不要求两台物理机器才能宣称 spike 跑通。
3. **延迟 HUD 或日志**。至少能算出视频 GG 和输入 feedback；HUD 与 CSV 二选一可跑，CSV 仍是对账格式。
4. **QUIC stream 组帧说明**。即下一节。Cocoa 按此组帧，不再各自发明头。

不在本周交付：M2 瓦片通道的实现（组帧草案见 [spike-m2-tiles.md](spike-m2-tiles.md)，M1 不发送）、公网 relay、WebRTC、音频、剪贴板、文件传输、多用户。

## 组帧草案（Cocoa 按此实现）

字节序：多字节整数与 IEEE-754 `float32` 都是 **little-endian**。结构体没有隐式填充，按下面的字节数紧凑排列。不知道的 `msg_type`：重置该 stream，不要把后面的字节当成下一条消息。

### 连接与 stream

一条 QUIC 连接上三条 stream：

| stream | 方向 | 谁打开 | `stream_kind` | 内容 |
| --- | --- | --- | --- | --- |
| control | 双向 | Client | `1` | 版本、口令、显示器列表、选择显示器 |
| video | 单向 Host → Client | Host | `2` | `VIDEO_CONFIG`、`VIDEO_FRAME` |
| input | 单向 Client → Host | Client | `3` | 鼠标、滚轮、键盘 |

每条 stream 的开头是 preface，不走下面的 envelope：

```text
offset  size  field
0       4     magic        ASCII "NDS0"  （4E 44 53 30）
4       1     stream_kind  u8            1 control, 2 video, 3 input
5       1     version      u8            本草案为 1
6       2     reserved     u16           0
```

Preface 不符则重置该 stream。种类放错（例如在 input stream 上收到 `VIDEO_FRAME`）同样重置。

Preface 之后是连续的消息，没有额外分隔符：

```text
offset  size  field
0       4     body_len   u32   此字段之后的字节数，含 msg_type 与 flags
4       2     msg_type   u16
6       2     flags      u16
8       N     body       N = body_len - 4
```

`body_len` 小于 4 是协议错误，关闭连接。一条消息读满 `4 + body_len` 字节再解析下一条。`flags` 在下面没定义的消息里必须为 0。

### 标识符

`channel_id`（`u8`）：

| 值 | 名字 | 本周 |
| --- | --- | --- |
| `1` | `hevc_main` | 默认 |
| `2` | `h264_fallback` | HEVC 不可用时 |
| `3` | `lossless_tile` | M1 禁止发送，收到则忽略。布局见 [spike-m2-tiles.md](spike-m2-tiles.md) |

`encoder_config_id`（`u16`）由 Host 分配，从 1 递增，0 非法。分辨率、codec、`channel_id` 或参数集变化就换新 id。

`frame_id` / `event_id`（`u64`）从 1 递增，视频和输入各自编号。

`display_id`（`u32`）等于 `CGDirectDisplayID`。

### Control stream

`HELLO` = `0x0001`。连接后 Client 的第一条消息。

```text
u16  major          = 1
u16  minor          = 0
u8   role           = 1     # 1 client
u8   name_len              # 0..64
u8   name[name_len]        # UTF-8 显示名，不含口令
```

`AUTH_PASSWORD` = `0x0002`。紧跟 `HELLO`。仅在 TOFU 通过且握手完成后发送。

```text
u16  password_len          # 1..128
u8   password[password_len]  # UTF-8
```

`AUTH_RESULT` = `0x0003`。

```text
u8   ok              # 1 成功，0 失败
u8   reason          # 0 none, 1 bad_password, 2 version
u16  reserved        # 0
```

失败则 Host 关闭连接。成功后 Host 发送 `DISPLAY_LIST`。

`DISPLAY_LIST` = `0x0004`。

```text
u16  count
u16  reserved
# 重复 count 次：
u32  display_id
i32  origin_x_pt
i32  origin_y_pt
u32  width_px
u32  height_px
u32  scale_num             # pixels = points * scale_num / scale_den
u32  scale_den
```

`SELECT_DISPLAY` = `0x0005`。Client → Host。

```text
u32  display_id
```

Host 收到后开始采集对应显示器，打开 video stream，先 `VIDEO_CONFIG` 再 `VIDEO_FRAME`。

### Video stream

`VIDEO_CONFIG` = `0x0101`。引用某个 `encoder_config_id` 的帧之前，必须先在 **同一条** video stream 上出现对应的 config。

```text
u16  encoder_config_id     # 非 0
u8   channel_id            # 1 或 2
u8   codec                 # 1 HEVC, 2 H264
u32  display_id
u16  coded_width
u16  coded_height
u16  fps_num               # 测量配置为 60
u16  fps_den               # 测量配置为 1
u8   chroma                # 1 = 4:2:0。本周只允许这个值
u8   reserved
u16  param_set_bytes
u8   param_sets[param_set_bytes]
```

`param_sets` 是 Annex-B：HEVC 为 VPS、SPS、PPS（含起始码）；H.264 为 SPS、PPS。

`channel_id = 3` 的 `codec`、`chroma` 和空参数集不在这里展开，见 [spike-m2-tiles.md](spike-m2-tiles.md)。M1 仍只发通道 1 或 2，并且 `chroma = 1`。

`VIDEO_FRAME` = `0x0102`。

```text
u64  frame_id              # 从 1 起
u16  encoder_config_id
u8   channel_id
u8   frame_flags
u16  dirty_rect_count      # 0..64
u16  reserved
u64  capture_mono_ns       # T0
u32  access_unit_bytes
NdRect rects[dirty_rect_count]
u8   access_unit[access_unit_bytes]   # Annex-B
```

`frame_flags`：

| bit | 名字 | 含义 |
| --- | --- | --- |
| 0 | `KEYFRAME` | IDR / 关键帧 |
| 1 | `DIRTY_COALESCED` | 脏矩形超过 64，已收成一个包围盒 |
| 2 | `DIRTY_NONE` | 没有脏矩形元数据；`dirty_rect_count` 必须为 0；输入匹配时把整帧视为已更新 |

`NdRect`，像素，采集缓冲区坐标，原点左上，y 向下：

```text
i32  x
i32  y
i32  width
i32  height
```

`width` 与 `height` 大于 0。ScreenCaptureKit 给出的矩形多于 64 个时，Host 收成一个包围盒，置 `DIRTY_COALESCED`，`dirty_rect_count = 1`。

M1 的 `access_unit` 是整帧码流。`rects` 不表示「只编码了这块」。`channel_id = 3` 时 `access_unit` 改为紧凑 BGRA，见 [spike-m2-tiles.md](spike-m2-tiles.md)。

### Input stream

下列消息的 body 都以同一段前缀开始：

```text
u64  event_id
u64  event_mono_ns
u32  display_id
```

`INPUT_MOUSE_MOVE` = `0x0201`。

```text
prefix
f32  x_px
f32  y_px
```

`INPUT_MOUSE_BUTTON` = `0x0202`。

```text
prefix
f32  x_px
f32  y_px
u8   button          # 0 left, 1 right, 2 middle
u8   action          # 1 down, 2 up
u16  reserved
```

移动中的按下（拖拽）连续发 `INPUT_MOUSE_MOVE`，按钮状态由 down/up 保持，不另设 drag 消息。

`INPUT_WHEEL` = `0x0203`。

```text
prefix
f32  x_px
f32  y_px
f32  delta_x
f32  delta_y
u8   unit            # 0 line, 1 pixel
u8   reserved[3]
```

`INPUT_KEY` = `0x0204`。

```text
prefix
u16  keycode         # CGKeyCode
u8   action          # 1 down, 2 up, 3 repeat
u8   modifiers       # bit0 shift, bit1 control, bit2 option, bit3 command, bit4 caps, bit5 function
u32  utf32           # Unicode scalar，没有则为 0
```

Host 用 `CGEventSetFlags` 带上 modifiers，再用 keycode 投递。`action = 3` 按一次额外的 key-down 注入。

`kind` 列（CSV）用消息名：`mouse_move`、`mouse_button`、`wheel`、`key`。

## 实现时不要做的事

- 不要把视频和输入写进同一条 QUIC stream。
- 不要在握手完成前发帧，也不要另开一条明文 UDP 传媒体。
- 不要把口令放进 Bonjour TXT、HUD 或 CSV。
- 不要用 WebRTC、公网 relay 或 M2 无损瓦片来达成本周目标。
- 不要把 VideoToolbox 当成 4:4:4 或 ROI QP 编码器。文字清晰度靠 TextEdit 对比来判断；不够就记下来留给 M2，而不是在 M1 编码器参数上碰运气。
