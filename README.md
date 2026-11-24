# WebrtcPhone App（双端统一发布仓库）

穿云投屏（ScrcpyOverWebRTC）Android + iOS 客户端的 monorepo 与统一编译发布中心。

- **Android 客户端**：源自 [hqw700/WebrtcPhone-Android](https://github.com/hqw700/WebrtcPhone-Android)，代码位于 `android/`。
- **iOS 客户端**：Swift + SwiftUI 主控端，代码位于 `ios/`，线协议与 Android 端逐字节对齐（见 `ios/docs/PROTOCOL.md`）。
- **CI/CD**：`.github/workflows/` 下的两条流水线在 GitHub 云端编译，产物发布到本仓库 Releases。

## 目录结构

```text
.
├── android/                       # Android 客户端（Gradle / Kotlin / Compose）
├── ios/                           # iOS 客户端（SwiftUI / XcodeGen）
│   ├── docs/PROTOCOL.md           # 双端对齐的线协议契约
│   ├── project.yml                # XcodeGen 工程定义
│   └── Sources/WebrtcPhone/       # Swift 源码（core/data/rtc/ui）
├── .github/workflows/
│   ├── build-android.yml          # Android: 测试 + 构建 + Release
│   └── build-ios.yml              # iOS: 归档 + 未签名 IPA + Release
└── README.md
```

## 编译与发布

两条流水线均由推送标签或手动触发，产物自动附加到同一个 GitHub Release。

| 流水线 | 触发标签 | Runner | 产物 |
|---|---|---|---|
| `build-android.yml` | `v*` / `android-*` | ubuntu-latest | debug + release APK |
| `build-ios.yml` | `v*` / `ios-*` | macos-latest | 未签名 IPA |

也可在 Actions 页面手动点 **Run workflow** 触发（不依赖标签）。

### 发布一个版本

```bash
git tag v0.4.5
git push origin v0.4.5
```

推送 `v*` 标签会同时触发双端构建；`android-*` / `ios-*` 前缀可单独构建某一端。

### 版本同步规则

- 版本号以 Android 上游 [`hqw700/WebrtcPhone-Android`](https://github.com/hqw700/WebrtcPhone-Android) 根目录 `VERSION` 文件为唯一准绳。
- 当前上游版本为 `v0.4.5`，本仓库 `android/VERSION` 也为 `v0.4.5`。
- 当上游 `VERSION` 升级时，先同步修改本仓库 `android/VERSION`，再推送同名 `v*` 标签发布；避免 Android/iOS 产物出现不同版本号。
- 日常发布优先使用统一 `v*` 标签；`android-*` / `ios-*` 仅用于单端调试。

## Android 签名配置

在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret | 说明 |
|---|---|
| `KEYSTORE_BASE64` | release.keystore 的 Base64 编码（`base64 -w0 release.keystore`） |
| `KEYSTORE_PASSWORD` | Keystore 密码 |
| `KEY_ALIAS` | 签名别名 |
| `KEY_PASSWORD` | 签名密钥密码 |

未配置时流水线仍会构建 debug APK 并上传；配置后才产出签名 release APK。

## iOS 签名说明

`build-ios.yml` 产出的是**未签名标准 IPA**，刻意不在 CI 内签名，原因是：

- **巨魔（TrollStore）**：直接打开 IPA 即安装，TrollStore 在安装时用假根证书重签（支持 iOS 14.0–16.6.1 / 17.0）。
- **企业 / 个人签名**：下载 IPA 后用签名工具（如爱思助手、AltStore、Sideloadly 或 `fastlane sigh resign`）重签再安装。

未签名包不含私有 entitlement，符合各签名方式的常规要求。如需在 CI 内直接产出企业签名包，可在 Secrets 中提供 `.p12` + `.mobileprovision` 后扩展流水线。

## iOS 已知限制

- 仅实现**主控端**（用 iPhone/iPad 控制远程 Android 云手机/真机），被控端 Host 模式不移植（iOS 无法部署 scrcpy agent）。
- WebRTC 硬解依赖 VideoToolbox；WS 备用通道为 H.264 + MediaCodec 对应实现。
- iOS 无法复制 Android 的 TLS ClientHello 拆包（DPI 规避）；如目标网络拦截 SNI，需服务端换端口/域名。
- 本地编译需要 macOS + Xcode；Windows/Linux 只能做静态检查，CI 在 macos runner 上完成真实编译。

## 相关项目

- 服务端与主体系：[ScrcpyOverWebRTC](https://github.com/hqw700/ScrcpyOverWebRTC)
- Android 上游：[WebrtcPhone-Android](https://github.com/hqw700/WebrtcPhone-Android)
