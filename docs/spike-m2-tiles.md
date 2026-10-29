# NearDesk M2 无损瓦片组帧

本文是 M2 第一刀的实现对齐说明。Cocoa 按此写 Host 分流和 Client 合成（代码里的 Viewer 就是协议里的 Client）。标识符、消息名、字段名保持英文。

标有「产品已钉」的条目来自 North 2026-10-29，实现不要改定义。标有「spike 草案」的阈值、字节布局和合成细节是这一刀的可执行合同：Host 与 Client 按此实现，测完可以改数字，但不要在测量前另选一套头。

M1 的成功条件、QUIC preface 和输入路径仍以 [spike-protocol.md](spike-protocol.md) 为准。本文只补 `lossless_tile`。

## 产品已钉

### 分流「产品已钉」

- 小脏区、文字、插入符：`channel_id = lossless_tile`（值 `3`，M1 已保留）。
- 大面积运动：继续有损通道。默认 `channel_id = hevc_main`（值 `1`）。HEVC 会话建不起来时，沿用 M1 的 `h264_fallback`（值 `2`），不要把大脏区改送瓦片来补清晰度。
- 按脏区面积分流。不要用 VideoToolbox 的色度、ROI 或分区 QP 来代替这条通道。

### 验收「产品已钉」

两条并列，都不能用另一条代替：

1. **打字清晰度。** 在 TextEdit 里打字时，经 NearDesk 看远端（或同机 loopback）画面，新打出来的字和插入符要清晰于系统「屏幕共享 / Screen Sharing」。比的是打字过程，不是一张静止桌面截图。双机怎么摆见 [spike-clarity-v1-v2.md](spike-clarity-v1-v2.md)；那份记录的是 M1 静止样品。本切片把门槛收到打字过程。
2. **延迟不得退步。** 同机 loopback、`clocksMatch == true`：glass-to-glass p50 ≤ 40ms、p95 ≤ 80ms，input feedback p50 ≤ 50ms。口径与 M1 相同（`T4_present − T0_capture`，以及 `T4_present − T_inject`）。双机 CSV 的 `gg_ns` / `feedback_ns` 继续留空，见 [spike-quic-extract.md](spike-quic-extract.md)。

### 范围「产品已钉」

本切片做脏区分流、`lossless_tile` 组帧、Client 把瓦片盖在 HEVC 底图上，并让两条通道都进入现有 `LatencyHub`。

不做：音频、公网、任何 relay、WebRTC、完整产品壳。Keychain 另开小切片，不写进本帧头。

## spike 草案

下面从这里开始都是 spike 草案。

### 常数

脏区面积用采集缓冲区像素，也就是 `SCStream` 输出、和 HEVC coded 尺寸同一套坐标。清晰度记录里的 UTM 1920×1200 画面，coded 尺寸是 1728×1080，面积按这块缓冲算，不按面板物理像素算。

| 符号 | 值 | 含义 |
| --- | --- | --- |
| `TILE_AREA_MAX` | `131072` | 单个矩形的 `width * height` 上限，含等号。1728×75 或 256×512 仍算小；再大走有损 |
| `TILE_EDGE_MAX` | `2048` | 宽或高超过则走有损。当前 coded 边长 ≤ 1920，这条是防 coded 尺寸变大 |
| `TILE_MAX_COUNT` | `8` | 一条瓦片消息里最多几个矩形 |
| `TILE_BYTES_MAX` | `524288` | 一条瓦片消息里像素字节之和的上限。等于 `TILE_AREA_MAX * 4` |
| 有损关键帧间隔 | `120` | 只数真正发出的有损帧，沿用 M1 的 `encodedCount % 120` |

这五个数不是产品已钉。打字 p95 被原始像素撑破、或 TextEdit 一行被划进 HEVC 导致发糊，Cocoa 可以改表，改完把新数字写回本文。单矩形 BGRA 字节数是 `width * height * 4`，用 64 位整数相乘。

`TILE_BYTES_MAX` 必须让整条消息落在现有 `maxBodyLength`（8 MiB）以内。本表满足。不要把一条瓦片拆成多条 `VIDEO_FRAME`。

### 一条采集怎么分流

先走 M1 的 `encodeDirtyRects`，不要另写一套合并。超过 64 个矩形时仍然收成一个包围盒，并带 `DIRTY_COALESCED`。分类在这之后进行。

`insideCoded(rect)`：`x ≥ 0`，`y ≥ 0`，`x + width ≤ coded_width`，`y + height ≤ coded_height`（64 位加法）。越出 coded 缓冲的矩形整块走有损，不裁剪。

`small(rect)` 为真，当且仅当 `insideCoded`，并且宽、高都 ≤ `TILE_EDGE_MAX`，并且面积 ≤ `TILE_AREA_MAX`，并且面积 × 4 ≤ `TILE_BYTES_MAX`。

```text
packed = encodeDirtyRects(...)

if packed 带 DIRTY_NONE:
    tileRects = []
    lossyKind = dirtyNone          # 有损整帧，dirty_rect_count = 0
else if packed.rects 为空:
    tileRects = []
    lossyKind = omit               # 可能整帧都不发，见下面的 sendLossy
else:
    candidates = []
    lossyRects = []
    for rect in packed.rects:
        if small(rect): candidates.append(rect)
        else: lossyRects.append(rect)
    tileRects, overflow = admit(candidates)
    lossyRects += overflow
    if lossyRects 为空:
        lossyKind = omit
    else:
        lossyKind = listed         # 有损帧头只带 lossyRects

admit(candidates):
    按 (area 升序, y 升序, x 升序, height 升序, width 升序) 排序
    admitted = []
    used = 0
    overflow = []
    for rect in candidates:
        need = width * height * 4
        if admitted.count == TILE_MAX_COUNT or used + need > TILE_BYTES_MAX:
            overflow += rect 以及它后面的所有候选
            break
        admitted.append(rect)
        used += need
    return admitted, overflow
```

候选已按面积升序。当前矩形因字节预算放不进时，后面的不会更小，一并改走有损。因 `TILE_MAX_COUNT` 放不进时，后面的也一并改走有损，不再挑较小的补位（排序已经把小的放在前面）。

`DIRTY_COALESCED` 的 packed 结果只有一个包围盒，不会再拆成「半块瓦片、半块 HEVC」。这个盒子要么整块进瓦片，要么整块进有损。

发送：

- `sendTile = tileRects 非空`
- `sendLossy = (lossyKind != omit) || 本会话还没有发过有损关键帧 || 几何有变化`
- `sendTile` 和 `sendLossy` 都为假：这一回调结束。不调用 VideoToolbox，不发消息，不递增 `frame_id`
- 几何（`display_id` 或 coded 宽高）变化且 `sendLossy`：这一帧有损消息带 `KEYFRAME`。无损通道若已经配置过，同一采集里先发新的 lossless `VIDEO_CONFIG`，即使本采集没有瓦片
- 其它 `sendLossy`：`KEYFRAME` 沿用 M1，已发出的有损帧计数在递增前为 0，或被 120 整除
- 只发瓦片的采集不调用 VideoToolbox，也不增加有损帧计数。打字路径因此不会为了凑关键帧间隔被插进一帧 HEVC

`frame_id` 仍从 1 起，每发出一次采集才加一。同一次采集的瓦片消息和有损消息共用这一个 `frame_id`。

有元数据、矩形为空、已经发过有损关键帧、几何也没变：不发送。若仍按 M1 发一帧 HEVC，这帧全图 4:2:0 会把刚才的瓦片盖掉，空帧的访问单元也会挡在下一次插入符前面。拿得到脏矩形列表时不要改标成 `DIRTY_NONE`。光标矩形很小，SCK 把它放进脏区时走瓦片。若实测光标不进脏区、静止回调被跳过后光标卡住，再改这条；测到之前按「不发送」实现。第一帧和几何变化即使脏区为空，仍然发有损 `KEYFRAME`。

例子（coded 1728×1080）：

| 脏区 | 面积 | 去向 |
| --- | --- | --- |
| 插入符 3×28 | 84 | `lossless_tile`，336 字节 |
| 一行字 640×32 | 20480 | `lossless_tile` |
| 通栏一行 1728×75 | 129600 | `lossless_tile` |
| 通栏再高 1 像素 1728×76 | 131328 | 有损整帧 |
| 拖窗口 800×600 | 480000 | 有损整帧 |
| SCK 给出 70 个矩形 | 先收成 1 个盒子 | 再按盒子面积二选一 |
| `DIRTY_NONE` | — | 只发有损，不发瓦片。这帧换掉 base，并清掉更旧的瓦片 |
| 有元数据但矩形为空，且已有关键帧、几何未变 | 0 | 不发送。已贴上的瓦片保持原样 |

会话第一采集即使全是小矩形，也要带一帧有损 `KEYFRAME`，让 Client 有底图。这一采集同时发瓦片。之后的纯小脏区只发瓦片。

### 像素从哪来

瓦片字节必须来自同一采集时刻的 `kCVPixelFormatType_32BGRA` 缓冲，坐标与 coded 尺寸一致。草案做法：`SCStream.pixelFormat` 用 32BGRA；只有 `sendLossy` 时才把整帧转成 4:2:0 送进 VideoToolbox。

不要从今天 M1 的 `420YpCbCr8BiPlanarFullRange` 里把色度放大后称作无损。那样文字仍然是 4:2:0。

`CVPixelBuffer` 的 `bytesPerRow` 可以有填充。拷进载荷时按紧凑行宽 `width * 4` 去掉填充。线上没有 stride 字段。

### 流拓扑

两条通道复用 Host 已经打开的那一条 video stream：preface `NDS0`，`stream_kind = 2`，`version = 1`。不新开第二条 video stream，不改 ALPN `neardesk-spike/1`，不改 preface version。

这条 stream 的 preface 只有一个视频种类。Host 在 `SELECT_DISPLAY` 之后打开一次，Client 只读这一条。`channel_id` 已经写在 `VIDEO_CONFIG` 和 `VIDEO_FRAME` 里，用来分路够用。输入仍在 `stream_kind = 3`。视频上的队头阻塞继续挡不住输入，M1 的这条产品已钉不动。

同一采集若两条都发，顺序固定为：

1. 这一采集需要的新 `VIDEO_CONFIG`（有损在前，无损在后）
2. `VIDEO_FRAME`，`channel_id = lossless_tile`
3. `VIDEO_FRAME`，`channel_id = hevc_main` 或 `h264_fallback`

瓦片在前，避免大块 HEVC 访问单元挡在插入符前面。

### `VIDEO_CONFIG`

复用 `msg_type = 0x0101`，不新造消息。M1 对未知 `msg_type` 会重置 stream。`channel_id = 3` 的帧今天会被 Client 丢掉，这条路径可以留在 `VIDEO_FRAME` 里。

字段顺序与 M1 相同。`lossless_tile` 的取值：

```text
u16  encoder_config_id     # 非 0，且不得等于当前有损通道的 id
u8   channel_id            # 3
u8   codec                 # 3 = raw_bgra
u32  display_id            # 与当前有损 config 相同
u16  coded_width           # 与当前有损 config 相同
u16  coded_height
u16  fps_num               # 测量配置 60
u16  fps_den               # 测量配置 1
u8   chroma                # 0。本通道不用；不是 4:2:0
u8   reserved              # 0
u16  param_set_bytes       # 0
```

`codec` 取值：

| 值 | 名字 | 通道 |
| --- | --- | --- |
| `1` | `hevc` | `hevc_main` |
| `2` | `h264` | `h264_fallback` |
| `3` | `raw_bgra` | `lossless_tile` |

通道与 codec 必须成对。`chroma` 只在通道 1 和 2 上为 `1`。通道 3 的 `chroma` 必须为 `0`，`param_sets` 必须为空。

M1 的解析器把 `chroma != 1` 当成坏消息。M2 Client 要改成：仅当 `channel_id == lossless_tile` 时接受 `chroma == 0` 且 `codec == raw_bgra`。旧 Client 会在第一条无损 config 上重置 video stream。本切片的 Host 和 Client 一起上，不为旧 Client 把 `chroma` 填成 `1`，也不在纯瓦片采集后面补一帧 HEVC。

`encoder_config_id` 继续由 Host 从 1 单调递增，两条通道共用一个计数器，所以不会撞号。各自记住「当前这一通道的 id」：

- 有损 id 在分辨率、codec、参数集变化时更换，规则同 M1。更换有损 id 不更换无损 id。
- 无损 id 在第一条瓦片之前发出，并在 `display_id`、coded 宽高或像素格式变化时更换。HEVC 参数集变化不更换无损 id。
- 帧的 `encoder_config_id` 必须等于该 `channel_id` 当前 config 的 id。瓦片引用有损 id，或有损帧引用无损 id，都是协议错误。

几何变化时，两条还活着的通道都换新 id，并在引用它们的帧之前把两份 config 都放上同一条 video stream。

### `VIDEO_FRAME`

复用 `msg_type = 0x0102`。固定头与 `NdRect` 和 M1 相同。`channel_id = 3` 时，`access_unit` 不是 Annex-B，而是紧凑 BGRA8。

```text
u64  frame_id
u16  encoder_config_id     # 当前 lossless config
u8   channel_id            # 3
u8   frame_flags
u16  dirty_rect_count      # 1 .. TILE_MAX_COUNT
u16  reserved              # 0
u64  capture_mono_ns       # 与同一次采集的有损帧相同
u32  access_unit_bytes     # 等于下面各矩形的 BGRA 字节之和
NdRect rects[dirty_rect_count]
u8   pixels[access_unit_bytes]
```

一次采集只发 **一条** 瓦片 `VIDEO_FRAME`。多个小矩形装在这条消息的 `rects` 里，而不是每个矩形一条消息。`rects` 的顺序就是 `admit` 的顺序。

矩形 `i` 的像素是 `pixels` 里的一段连续字节，按 `rects` 顺序拼接，没有间隙：

```text
offset = 0
for rect in rects:
    nbytes = rect.width * rect.height * 4
    blit pixels[offset .. offset + nbytes)
    offset += nbytes
# offset 必须等于 access_unit_bytes
```

一个矩形内部按行优先、从上到下、从左到右。第 `r` 行起点是 `r * width * 4`，像素 `c` 再偏移 `c * 4`。每个像素 4 字节：`B, G, R, A`。Host 把 `A` 写成 `0xFF`。Client 把瓦片当不透明块贴上，不使用 alpha 混合。

有损帧的 `rects` 只列出走有损的那些矩形，含义仍是 M1 的注解：访问单元是整帧，不是裁切编码。被瓦片带走的矩形不要再写进有损帧头。

`frame_flags`：

| bit | 名字 | 瓦片消息 | 有损消息 |
| --- | --- | --- | --- |
| 0 | `KEYFRAME` | 必须为 0。瓦片不是 IDR，也不重置 HEVC 参考帧 | 与 M1 相同，只标记这一条有损访问单元 |
| 1 | `DIRTY_COALESCED` | 仅当 packed 是单个包围盒且该盒子被收进瓦片 | 仅当这个盒子被收进有损 |
| 2 | `DIRTY_NONE` | 必须为 0，且 `dirty_rect_count ≥ 1` | 与 M1 相同。这种采集没有瓦片消息 |

同一 `frame_id` 在 stream 上可以出现两次，而且只允许这个顺序：先 `lossless_tile`，再有损通道。`frame_id` 在 stream 上不下降。同一通道上 `frame_id` 不重复。下降、同通道重复、或有损消息出现在同 id 瓦片之前，都重置 video stream。

瓦片不代替 IDR。有损解码器只吃通道 1 或 2。丢了有损参考帧时，恢复仍靠下一条有损 `KEYFRAME`，不靠瓦片。

协议错误（config 未先到、id 和通道对不上、瓦片带了 `KEYFRAME` 或 `DIRTY_NONE`、矩形为空或越界、像素字节数对不上、`reserved != 0`）重置这条 video stream。不要跳过坏消息继续读，边界会对不齐。

### Client 合成

Client 保住三样东西：

- `base`：最近一帧已经解码的有损画面，记下它的 `frame_id`。会话开始时没有 base。
- `overlays`：还没被更新的 base 盖掉的瓦片，每块带自己的 `frame_id` 和矩形。
- 一份当前画面，尺寸来自 config 的 coded 宽高。两份 config 的 `display_id` 和 coded 尺寸必须一致，否则重置 stream。

绘制：有 base 就从 base 拷起，没有就用不透明黑底（BGRA `0,0,0,0xFF`）。然后按 `frame_id` 升序画 overlay；同一条消息里按 `rects` 顺序画。重叠处后画的覆盖先画的。Host 可以原样留下 SCK 的重叠矩形，不必先减掉。

有损 `VIDEO_FRAME` 到达，`frame_id = F`：

1. 用 M1 的解码器解这一条，换成新的 `base`。呈现合成结果，不把裸的 HEVC 缓冲直接交给画面。
2. 丢掉 `frame_id < F` 且与本帧任一有损脏矩形相交的 overlay。相交则整块丢掉，不裁切。`DIRTY_NONE` 或几何已经变化时，丢掉全部 `frame_id < F` 的 overlay。
3. `frame_id == F` 的 overlay 一律留着，画在新 base 上面，盖住 HEVC 在这些矩形里的 4:2:0。不相交的更旧瓦片也留着，别处的大块运动不会把已经锐化的字盖回去。
4. 若这个 `frame_id` 已经因为瓦片呈现过，只更新画面，不要再记一次延迟。
5. `DIRTY_NONE` 只会出现在这种有损帧上：整帧算更新，输入匹配规则与 M1 相同。这一采集没有瓦片。

瓦片 `VIDEO_FRAME` 到达，`frame_id = F`：

1. 若已有 base 且 `base.frame_id > F`，丢掉这条瓦片。更新的底图已经覆盖它；按发送顺序这不该发生。
2. 否则把各矩形放进 overlay，立刻合成并呈现。不等待同 id 的有损帧，也不存在「请补 IDR」这种消息。
3. 还没有任何 base 时，瓦片画在黑底上并呈现。会话第一采集会紧接着送来有损关键帧；关键帧到达后按上面的规则重画，同 id 瓦片仍然盖在上面。第一眼可能是黑底上的字，随后补上桌面，字保持锐利。

`DIRTY_COALESCED` 对 Client 只表示「这里是一个包围盒」。不要把它拆回多个矩形。

几何变化：丢掉旧尺寸的 base 和全部 overlay，等新的有损关键帧。新尺寸的瓦片可以先画在新的黑底上。

### 延迟

`LatencyHub` 的 CSV 表头不改。一行对应一个 `frame_id`。`clocksMatch` 仍只在 Client 连到 loopback 时为真，两边继续用 `mach_continuous_time`。不要为了瓦片开另一套钟，也不要在双机上填 `gg_ns`。

每个 `frame_id` 只调用一次 `noteHostVideo`、一次 `noteClientVideo`、一次 `notePresented`。同一次采集的后到的那条有损帧若已经为瓦片记过账，就只更新 base，不再入账。当前实现用 `frame_id` 当字典键，第二次写入会顶掉第一次或被 `writtenVideo` 丢掉；按一次来写，入账的才是真正呈现的那条。

| | 只发瓦片 | 只发有损 | 两条都发 |
| --- | --- | --- | --- |
| 入账的 `channel_id` | `3` | `1` 或 `2` | `3` |
| `dirty_rect_count` | 瓦片矩形数 | 有损帧头里的矩形数 | 瓦片矩形数 |
| `au_bytes` | 像素字节数 | Annex-B 长度 | 像素字节数 |
| T0 | `capture_mono_ns` | 同 M1 | 两条消息上的同一个 T0 |
| T1 | BGRA 拷贝完成 | VideoToolbox 完成 | 瓦片拷贝完成 |
| T2 | 瓦片消息交给 QUIC | 有损消息交给 QUIC | 瓦片消息交给 QUIC |
| T3 | 读到瓦片消息 | 读到有损消息 | 读到瓦片消息 |
| T4 | 合成呈现 | 解码结果呈现 | 瓦片那一次呈现 |

玻璃到玻璃仍是这一行的 `T4 − T0`。混合采集不把 HEVC 编码完成时刻写进这一行，否则打字样本会把有损尾巴算进去，p50 会被拉过产品已钉的线。大运动采集没有瓦片，整行仍是有损时间，和 M1 一样。

输入匹配不变：呈现过的帧里，取 `capture_mono_ns ≥ T_inject` 的第一帧，且该帧带脏矩形或 `DIRTY_NONE`。带矩形的瓦片算数。同 id 的有损帧不要再 `notePresented` 一次，避免同一个 T0 占住下一次按键，也避免滚动窗口里一次采集算两行。

因此 CSV 里打字时会出现 `channel_id = 3`，拖动大窗口时仍是 `1` 或 `2`。两条通道都会进 `LatencyHub`，只是同一次采集只贡献一行。同一采集里如果又有插入符又有大块脏区，这一行记瓦片；大块的有损时间不进 p50。拖窗口的延迟样本来自「这一采集没有瓦片」的帧。想看 HEVC 尾巴就另写调试日志，不要塞进 p50 的窗口。空脏区没有行。

滚动窗口仍是视频约 300 帧、输入约 100 次。验收时读同机 loopback 的 p50 / p95，标准就是上面的产品已钉。

## 实现时不要做的事

- 不要新开 `msg_type` 来装瓦片。未知类型会重置 M1 的 video stream。
- 不要新开第二条 video stream，也不要改 `NDS0` / ALPN 来标记 M2。
- 不要用 VideoToolbox 色度或 ROI 代替面积分流。
- 不要把 4:2:0 采集缓冲放大后放进 `raw_bgra`。
- 不要在纯瓦片采集上调用 VideoToolbox，也不要为了旧 Client 再附带一帧 HEVC。
- 不要让瓦片消息带 `KEYFRAME`，也不要让它重置有损解码器。
- 不要为同一个 `frame_id` 写两行延迟 CSV。
- 不要在双机上把 `gg_ns` 填上。那一列只在 `clocksMatch` 的 loopback 里有定义。
