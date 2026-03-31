# 🎙️ DoubaoWatch — Apple Watch × 豆包语音大模型

通过 Apple Watch 麦克风与豆包端到端实时语音大模型 (RealtimeAPI) 进行语音对话。

## 项目结构

```
DoubaoWatch/
├── DoubaoWatch.xcodeproj/        # Xcode 项目文件
├── DoubaoWatchApp/               # iPhone companion app（WebSocket 代理层）
│   ├── App.swift
│   ├── ContentView.swift
│   ├── DoubaoRealtimeClient.swift
│   └── WatchSessionManager.swift
└── DoubaoWatch WatchKit Extension/  # Watch 主体
    ├── WatchApp.swift
    ├── WatchContentView.swift
    ├── WatchAudioEngine.swift
    └── WatchViewModel.swift
```

## 架构说明

```
[Apple Watch]
  麦克风 PCM → WatchAudioEngine
                ↓ WatchConnectivity
[iPhone App]
  DoubaoRealtimeClient → WebSocket → 豆包 RealtimeAPI
                ↓ WatchConnectivity（音频/文字回传）
[Apple Watch]
  播放 TTS 音频 + 显示识别文字
```

> Apple Watch 本身无法直接建立 WebSocket 连接到外部服务器（系统限制），因此采用 iPhone 作为"代理桥"：Watch 捕获音频 → 通过 WatchConnectivity 发给 iPhone → iPhone 与豆包 RealtimeAPI 建立 WebSocket → 回传 TTS 音频和文字给 Watch 播放。

## 配置

在 `DoubaoWatchApp/DoubaoRealtimeClient.swift` 中填入：

```swift
let APP_ID     = "你的AppID"
let ACCESS_KEY = "你的AccessKey"
let APP_KEY    = "你的AppKey"    // 用于鉴权 Header
```

## 支持的模型版本

- **O版本 / O2.0版本**：精品音色（vv、xiaohe、yunzhou、xiaotian）
- **SC版本 / SC2.0版本**：克隆音色

本 Demo 默认使用 O2.0 版本 + `vv` 音色。

## 音频规格

| 方向       | 格式  | 采样率 | 声道 | 位深    |
|-----------|-------|--------|------|---------|
| 上行（录音）| PCM   | 16000  | 单声道 | Int16 LE |
| 下行（TTS）| OGG/Opus | 默认 | — | — |

## 快速上手

1. 用 Xcode 15+ 打开 `DoubaoWatch.xcodeproj`
2. 填入鉴权信息（AppID / AccessKey / AppKey）
3. 选择真机（Watch 模拟器无麦克风）
4. Run → 在 Watch 上点击 🎙️ 按钮开始说话
