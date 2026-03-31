# 🛠️ 接入指南

## 一、获取豆包鉴权信息

1. 登录 [火山引擎控制台](https://console.volcengine.com/)
2. 进入 **豆包语音** → **端到端实时语音大模型**
3. 创建应用，获取：
   - `AppID`（AppId）
   - `AccessKey`（访问密钥）
   - `AppKey`（用于 Authorization Header）
4. 开通 **O2.0 版本** 套餐（或 SC2.0 如需克隆音色）

## 二、填写配置

打开 `DoubaoWatchApp/DoubaoRealtimeClient.swift`，修改：

```swift
struct DoubaoConfig {
    static let appID     = "12345678"          // 替换为你的 AppID
    static let accessKey = "your-access-key"   // 替换为你的 AccessKey
    static let appKey    = "your-app-key"      // 替换为你的 AppKey
    static let modelVersion = "1.2.2.2"        // O2.0 版本
    static let speaker = "zh_female_vv_jupiter_bigtts"  // 音色
}
```

## 三、Xcode 配置

### 必须操作

1. **打开项目**：在 Xcode 15+ 中打开 `DoubaoWatch.xcodeproj`
2. **Signing**：
   - `DoubaoWatchApp` → Targets → Signing → 选择你的 Team 和 Bundle ID
   - `DoubaoWatch WatchKit Extension` → 同上，Bundle ID 必须是 iPhone App Bundle ID 加 `.watchkitextension`
3. **Capabilities**：
   - 两个 Target 都需开启 **WatchConnectivity**
   - Watch Extension 需开启 **Microphone**（entitlements 里加 `com.apple.developer.watchkit`）
4. **Deployment Target**：watchOS 9.0+，iOS 16.0+

### 权限检查

Watch Extension 的 `Info.plist` 已包含：
- `NSMicrophoneUsageDescription`
- `UIBackgroundModes: audio`

## 四、运行

1. 连接 iPhone + Apple Watch（真机必须配对）
2. 选择 iPhone 作为 Run Destination
3. ▶ Run → iPhone App 和 Watch App 会同时安装
4. 在 Watch 上找到 **豆包助手** 应用，点击打开
5. 点击 **🎙️** 按钮开始说话！

## 五、使用流程

```
用户点击 🎙️
    ↓
Watch 开始录音（显示波形动画 + "在听…"）
    ↓
再次点击 ■ 或静音检测停止
    ↓
Watch 显示 "思考中…"（三点动画）
    ↓
AI 回复语音通过扬声器播放（显示 "回复中" + 文字）
    ↓
播放完毕回到 idle 状态
```

**打断**：AI 说话时再次点击按钮可立即打断并重新录音。

## 六、已知限制

| 限制 | 说明 |
|------|------|
| 需要 iPhone 配套 | Watch 无法直接建 WebSocket，需 iPhone 作中转 |
| 无法在模拟器测试录音 | Watch 模拟器没有麦克风，需真机 |
| WatchConnectivity 延迟 | iPhone ↔ Watch 数据传输有 ~100ms 延迟，TTS 播放会有轻微滞后 |
| 后台保活 | iPhone App 进后台后 WebSocket 可能被系统终止，建议保持前台 |
| 限流 | 默认 60 QPM / 10000 TPM，高频使用需申请提额 |

## 七、可选优化

### 优化1：Watch 独立运行（需越过系统限制）

watchOS 7+ 支持 Independent App，但仍无法直接 WebSocket 到外部服务器。
可考虑在 Watch 端启 HTTP/2 连接（需服务器支持），或使用 CloudKit 中转。

### 优化2：本地静音检测（VAD）

在 `WatchAudioEngine` 中计算 RMS 音量，静音超过 1.5s 自动停止录音：

```swift
let rms = sqrt(samples.map { Double($0 * $0) }.reduce(0, +) / Double(count))
if rms < 100 { silenceCounter += 1 } else { silenceCounter = 0 }
if silenceCounter > 12 { stopRecording() }  // ~1.5s @ 100ms chunk
```

### 优化3：多轮对话上下文

豆包 RealtimeAPI 支持 `ConversationCreated` 等事件维护上下文，
可在 `DoubaoRealtimeClient` 中扩展实现多轮对话记忆。
