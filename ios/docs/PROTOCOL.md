# 与 Android 端对齐的线协议契约（iOS 移植依据）

> 来源：`WebrtcPhone-Android` v0.4.5 源码逐字段提取。所有字段名/字符串字面量/偏移量均为原文，iOS 端必须逐字节对齐。任何改动需同步修改 Android 端，否则互通会断。
>
> 约定：JSON 中 `null` 值在 Android 端 `org.json.put(key, null)` 会**移除该键**；Swift 端以 `nil` 不写入字典对齐。

---

## 1. 信令协议（Signaling WS `/connect_client`）

### 1.1 鉴权
- 登录用户：`Authorization: Bearer <token>` 请求头。
- 分享访客：仅 query `?share_token=<urlencoded>&share_pwd=<urlencoded>`（pwd 非空才带）。

### 1.2 出站消息（客户端 → 信令）

| 场景 | JSON |
|---|---|
| connect | `{"message_type":"connect","device_id":<id>}` |
| forward 通用 | `{"message_type":"forward","device_id":<id>,"payload":<obj>}` |
| request-offer payload | `{"type":"request-offer","ip_preference":"auto","scrcpy_options":<见§2>,"projection_resume_key":<32位无横线UUID>}` |
| answer payload | `{"type":"answer","sdp":<sdp>}` |
| ice-candidate payload | `{"type":"ice-candidate","candidate":{"candidate":<sdp>,"sdpMLineIndex":<int>,"sdpMid":<mid>,"mid":<mid>}}` |
| projection-end payload | `{"type":"projection-end","projection_resume_key":<key>}` |
| ping（裸串） | `{"type":"ping"}`  ← 无 message_type，每 20s |

`projection_resume_key`：`UUID().uuidString.replacingOccurrences(of:"-",with:"")`，按 (endpoint,deviceId,auth) 缓存复用。

### 1.3 入站消息（type 取 `message_type`，为空回退 `type`）

| type | 字段 |
|---|---|
| `pong` | 忽略 |
| `config` | `ice_servers`: [{`urls`(数组或字符串)/`url`, `username`?, `credential`?}] |
| `device_info` | `device_info`: 对象（见 §7 DeviceInfo） |
| `device_msg` | `payload`: 内嵌消息，按 payload.type 分派 |
| `error` | `code`, `error`(回退 `msg`，默认"服务器错误") |
| `offer`/`answer`/`ice-candidate` | 直接作为 payload 解析 |

payload.type 分派：
- `projection_status`：`state` ∈ `waiting / rejected / expired / busy / unattended_denied / ended / failed`
- `offer`：`sdp`（非空才有效）
- `answer`：`sdp`
- `ice-candidate`：`candidate` 对象（回退 payload 本身）；`candidate`=`candidate` 字段，`sdpMid`=`sdpMid`→`mid`→nil，`sdpMLineIndex` 默认 0

特判错误码：`SHARE_IN_USE` → "该分享正被其他访客使用，单个分享同时仅允许一人在线"。

---

## 2. ScrcpyOptions（`request-offer` 的 `scrcpy_options`）

公共字段（两种模式都发）：

| 键 | 值 | 默认 |
|---|---|---|
| `max_fps` | Int | 30 |
| `max_size` | Int | 1080（0=不限） |
| `bitrate` | Int(bps) | 4_000_000 |
| `min_bitrate` | Int(bps) | 1_000_000 |
| `max_bitrate` | Int(bps) | 20_000_000 |
| `bwe` | Bool | true |
| `audio` | Bool | true |
| `audio_gain` | Int | 1（字面量） |
| `audio_source` | String | "output"（字面量） |
| `audio_dup` | Bool | true（字面量） |
| `audio_low_latency` | Bool | false（字面量） |
| `power_off` | Bool | false |

屏幕模式：`"video_source":"display"`。
摄像头模式：`"video_source":"camera"` + `camera_facing`="back"、`camera_id`="0"、`camera_size`="1920x1080"、`camera_fps`=30、`camera_high_speed`=false、`camera_ar`="16:9"、`camera_zoom`=Double、`camera_orientation`="auto"、`camera_low_power`=false；若 `micAudio=true` 覆盖 `audio=true` + `audio_source="mic"`。

> **`video_source` 两种模式必须显式发送**——agent 跨会话保留上次取值。

---

## 3. 输入与剪贴板协议

### 3.1 input-channel（agent 创建）
| type | 字段 |
|---|---|
| `touch` | `id`,`seq`,`client_ts_ms`,`action`,`x`,`y`,`w`,`h`（action 3→1；坐标是帧像素，w/h 为帧尺寸） |
| `inject_keycode` | `action`,`keycode`,`repeat`,`meta` |
| `inject_text` | `text`（非 ASCII 由 agent 转剪贴板落屏） |
| `inject_scroll` | `seq`,`client_ts_ms`,`x`,`y`,`w`,`h`,`scroll_h`,`scroll_v` |
| `hard_keyboard` | `action`: "on"/"off"（**勿发**，agent 会停视频） |

`seq` 由 touch/scroll 共用自增（首值 1）。`press`=DOWN(0)+UP(1)；`longPress`=DOWN + 20×repeat(1..20) + UP。
Android keycode：HOME=3 BACK=4 VOL_UP=24 VOL_DOWN=25 POWER=26 TAB=61 ENTER=66 DEL=67 MENU=82 PLAY_PAUSE=85 PGUP=92 PGDN=93 ESC=111 FWD_DEL=112 MUTE=164 APP_SWITCH=187 SCREENSHOT=120 NOTIFICATION=83 WAKE=224 SLEEP=223。
TouchAction：DOWN=0 UP=1 MOVE=2 CANCEL=3。

### 3.2 clipboard-channel（agent 创建）
- 发 `set_clipboard`：`{"type":"set_clipboard","text":<s>,"paste":<bool,默认false>,"source":"local"}`（防回环：与 lastSynced 相同则跳过）。
- 发 `get_clipboard`：`{"type":"get_clipboard"}`。
- 收 `clipboard`：`text` 非空、`source != "keyboard"`、与 lastSynced 不同才接受。

---

## 4. 文件通道（`file-channel`，本端创建，协商前）

| 发 | 字段 | 收 | 字段 |
|---|---|---|---|
| `list` | `path` | `list_reply` | `success`,`error?`,`files[]`:{name,path,is_dir,size,mod_time(秒→ms ×1000)} |
| `mkdir` | `path` | `mkdir_reply` | `success`,`error?` |
| `delete` | `path` | `delete_reply` | `success`,`error?` |
| `install_apk` | `path`,`request_id`(String) | `install_status` | `status`,`message` |
| `upload_start` | `path`,`size`,`sha256`(小写hex),`install_on_finish` | `upload_reply` → 二进制块 → `upload_ack` | `success`,`error?`;ack:`finished`,`success?`(默认true),`error?` |
| `download_start` | `path`,`request_id` | `download_reply` → 二进制块(无 request_id) | `success`,`size`,`error?` |
| `upload_cancel` / `download_cancel` | `path` | — | — |

- 块大小 16384 字节；流控 `bufferedAmount > 1MiB` 时 delay 4ms。
- SHA-256：64KB buffer 流式计算，小写 hex。
- 超时：回复 15s、停滞 30s。下载二进制帧无 request_id，**必须串行**。

---

## 5. 终端通道（`adb-channel`，本端创建，协商前）
- 首帧（binary）：UTF-8 `{"type":"init","rows":<int>,"cols":<int>}`。
- 之后双向裸 PTY 字节；**不支持 resize**（init 后任何字节都写入 shell）。
- 输出缓冲 512KiB，落后时重置并回放最近内容。

---

## 6. WS 备用投屏协议（纯 TCP）

- URL：`/connect_client?token=<token>`。
- **PREV 帧 49 字节头（大端）**：
  - `[0..4)` magic `"PREV"`
  - `[4..36)` device_id（UTF-8，`\0` 右填充）
  - `[36]` 关键帧标志（==1）
  - `[37..45)` ptsUs（uint64 BE）
  - `[45..49)` payloadLen（uint32 BE）
  - `[49..)` H.264 Annex-B NALU
  - 音频 magic `"AUDO"` 未实现。
- `start_preview`：`{"message_type":"start_preview","type":"start_preview","device_id":<id>,"fps":<int>?,"max_size":<int>?,"bitrate":<bps>?,"stay_awake":true}`（>0 才带；bitrate≥10000 视为 bps）。
- `stop_preview`：`{"message_type":"stop_preview","type":"stop_preview","device_id":<id>}`。
- `group_control_event`：`{"message_type":"group_control_event","target_device_ids":[<id>],"event":<§3.1 输入事件>}`（顶层无 type）。
- WS 模式仅视频+输入，无音频/文件/终端/截图/镜像。

---

## 7. REST API（Base = `http(s)://host:port`，默认端口 8443）

除 login 外均带 `Authorization: Bearer`。错误体：纯文本 或 `{error|msg}` JSON。`{code,msg,data}` 信封 code≠0 → Business。

| 方法 路径 | 请求 | 响应要点 |
|---|---|---|
| POST `/api/login` | `{username,password}` | `{token,username?,role?}` |
| POST `/api/logout` | `{}` | —（错误吞掉） |
| GET `/api/me` | — | Me |
| GET `/devices` | — | 数组 或 `{devices:[]}` |
| DELETE `/api/devices/{id}` | — | — |
| POST `/api/devices/alias` | `{device_id,alias}` | — |
| GET `/api/tags` | — | `{tags:[],deviceTags:{}}` |
| POST `/api/tags` | `{tags:[{id,name,color}],deviceTags:{dev:[tagId]}}` | — |
| GET `/api/quick_texts` | — | 数组 |
| POST `/api/quick_texts` | 数组 `[{id,title,content,auto_enter,created_at}]` | — |
| GET `/snapshots/{id}.jpg` | If-None-Match | 304 / JPEG |
| GET `/api/files` | — | 数组 `[{name,size,updated_at,url,owner}]` |
| POST `/upload?name=` | octet-stream | — |
| GET `/api/files/url?name=` | — | `{url}` 相对签名路径 |
| DELETE `/api/files?name=` | — | — |
| POST `/api/tasks` | `{type, targets:[], payload, dest_path}` | `{task_id}`；type=install/push_file |
| GET `/api/tasks/details?task_id=` | — | `{task_id,type,devices:{}}` |
| POST `/api/share/create` | `{device_id,expire_seconds,access_mode,password,description,allow_clipboard,allow_file_tx,custom_card_code}` | 信封 `{data:{token,card_code,...}}` |
| GET `/api/share/list` / `?device_id=` | — | 信封 data 数组 |
| POST `/api/share/revoke` / `/extend` | `{token}` / `{token,extend_seconds}` | 信封 |
| GET `/api/admin/users` | — | 数组 或 "null" |
| POST `/api/admin/users/{create,delete,update,update_note,reset_password,kick}` | 见 Models | — |
| POST `/api/admin/users/update` | `{username,expire_seconds,policy?}` | expire:-1 不变,0 永久,>0 秒 |
| GET `/api/admin/leases?user=&device=&status=` | — | 数组 |
| POST `/api/admin/leases/{create,extend,revoke,update}` | 见 Models | Lease |

`policy` 7 键：`forbid_bitrate,forbid_fps,forbid_resolution,forbid_audio,forbid_file_push,forbid_terminal,forbid_share`。
分享链接：`endpoint.url("/share?token="+encode(token))`。

英文错误→中文：`Invalid username or password`→用户名或密码错误；`Username and password are required`→请输入用户名和密码；`Username already exists`→用户名已存在；`Unauthorized`→登录已失效，请重新登录；`Forbidden`→无权限执行此操作；`Share token not found`→分享不存在或已失效。

---

## 8. 实时订阅（DashboardSocket，`/connect_client`）

登录用户带 Bearer，不发 connect 即纯订阅。入站 message_type：

| type | 字段 | 事件 |
|---|---|---|
| `device_list_update` | `devices` | Devices |
| `snapshot_update` | `data`(data URI base64),`device_id` | SnapshotData |
| `snapshot_updated` | `device_id`,`hash` | SnapshotUpdated（hash≠缓存 ETag 才拉取） |
| `tags_update` | `tags`,`deviceTags` | Tags |
| `device_screen_state` | `device_id`,`screen_state` | ScreenState |

心跳 `{"type":"ping"}` 每 20s；退避 1/2/4/8/16/30s 封顶；401 → 登出。HTTP 兜底轮询：WS 断开时每 15s 刷设备、20s 刷缩略图。

---

## 9. 安全契约

- **TLS TOFU**：先系统 CA；失败时仅当叶子证书 DER 的 SHA-256（大写冒号分隔）等于已固定值（忽略大小写）才放行，并校验有效期；主机名不匹配但指纹匹配也放行。**绝不 trust-all。**
- 固定存储键 `pin:<host:port>`，值 `sha256|pinnedAtMs|subject`；`changed=true` 表示此前固定过但不匹配（可能中间人/换证书）。
- iOS 实现：`URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` 内 `SecTrustEvaluateWithError` + `SecTrustCopyCertificateChain` 取叶子，算 SHA-256（CryptoKit）。
- **凭据**（token、记住密码）只进 Keychain（kSecClassGenericPassword，accessibility whenUnlockedThisDeviceOnly），不进 UserDefaults/日志/URL。Keychain 写失败删键，读失败清空并退化重新登录。
- 会话 JSON：`{"server","token","username","role"}`；记住密码键 `pwd:<url>|<username>`；普通 prefs `session_meta`: `recent_servers`(≤6)、`remember_password`(默认 true)。
- 明文 HTTP 仅兼容服务端 `-tls=false`，UI 必须提示"不安全连接"。
- 网络超时：connect 10s / read-write 20s；WS 无读超时 + 25s ping；仅 HTTP/1.1。
- iOS 无法控制 TLS ClientHello 拆包（Android 有 1 字节+10ms 拆包绕 DPI）；若目标网络触发 DPI 拦截，需服务端换端口/域名或使用代理，属已知限制。

---

## 10. 关键差异与不可移植项

- **被控端 Host 模式整体移除**：Root/Shizuku、`cloudphone-agent` 部署、`/data/local/tmp`、投影服务、开机自启均不移植。
- `hard_keyboard` 不发（agent 停视频）；PTY 无 resize。
- 触控坐标用设备逻辑分辨率（`device_info.displays[0]`，方向不一致宽高互换），非视频帧尺寸。
- `file-channel`/`adb-channel` 必须在 SDP 协商前创建。
- RtcSession 全部状态在单线程 executor 变更；DataChannel 回调只拷贝数据后转投，回调内不同步 send/close。
