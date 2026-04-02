// WatchViewModel.swift
// Apple Watch 侧：业务逻辑层，协调音频引擎与 WatchConnectivity
// 支持：VAD 自动停止、多轮上下文、打断 AI 说话

import Foundation
import WatchConnectivity
import Combine

enum ConversationState: Equatable {
    case idle
    case connecting
    case listening       // 录音中（含 VAD 静音倒计时）
    case thinking        // ASR 结束 → TTS 开始之间
    case speaking        // AI 播放 TTS 中
    case error(String)

    static func == (lhs: ConversationState, rhs: ConversationState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting),
             (.listening, .listening), (.thinking, .thinking),
             (.speaking, .speaking): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

final class WatchViewModel: NSObject, ObservableObject {

    @Published var state:      ConversationState = .idle
    @Published var asrText:    String = ""
    @Published var replyText:  String = ""
    @Published var turnCount:  Int    = 0   // 已完成的对话轮数

    let audioEngine = WatchAudioEngine()

    override init() {
        super.init()
        setupWatchConnectivity()
        setupAudioCallbacks()
    }

    // MARK: - 公开接口

    /// 主按钮：根据状态切换
    func handleMicButton() {
        switch state {
        case .idle:
            startListening()

        case .listening:
            // 手动停止录音
            audioEngine.stopRecording()
            state = .thinking
            sendCommand("stop")

        case .speaking:
            // 打断 AI 说话，重新开始录音
            audioEngine.stopPlaying()
            state = .idle
            startListening()

        case .thinking, .connecting:
            // 忙碌时点击 → 取消
            audioEngine.stopRecording()
            sendCommand("stop")
            state = .idle

        case .error:
            state = .idle
        }
    }

    /// 清除本次对话文字
    func clearTexts() {
        asrText   = ""
        replyText = ""
    }

    // MARK: - 私有：录音流程

    private func startListening() {
        guard WCSession.default.isReachable else {
            state = .error("请打开 iPhone 上的 Xiaolan App")
            return
        }
        state     = .connecting
        asrText   = ""
        replyText = ""

        sendCommand("start", replyHandler: { [weak self] _ in
            DispatchQueue.main.async {
                self?.audioEngine.startRecording()
                self?.state = .listening
            }
        })
    }

    // MARK: - 私有：音频引擎回调

    private func setupAudioCallbacks() {
        // PCM 块 → 发给 iPhone
        audioEngine.onPCMChunk = { data in
            guard WCSession.default.isReachable else { return }
            WCSession.default.sendMessageData(data, replyHandler: nil) { err in
                print("[WatchVM] sendAudio error: \(err)")
            }
        }

        // VAD 检测到说话结束 → 自动提交
        audioEngine.onSpeechEnded = { [weak self] in
            guard let self = self, self.state == .listening else { return }
            self.state = .thinking
            self.sendCommand("stop")
        }
    }

    // MARK: - 私有：WatchConnectivity 发送

    private func sendCommand(_ cmd: String, replyHandler: (([String: Any]) -> Void)? = nil) {
        if let handler = replyHandler {
            WCSession.default.sendMessage(["cmd": cmd], replyHandler: handler) { err in
                DispatchQueue.main.async { self.state = .error(err.localizedDescription) }
            }
        } else {
            WCSession.default.sendMessage(["cmd": cmd], replyHandler: nil) { err in
                print("[WatchVM] sendCmd error: \(err)")
            }
        }
    }

    // MARK: - 私有：WatchConnectivity 初始化

    private func setupWatchConnectivity() {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }
}

// MARK: - WCSessionDelegate (Watch 侧)

extension WatchViewModel: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        print("[WatchVM] WC activated: \(activationState.rawValue), err: \(String(describing: error))")
    }

    /// TTS PCM 音频块（iPhone 发来的二进制）
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        audioEngine.enqueueAudio(messageData)
        DispatchQueue.main.async {
            if self.state == .thinking { self.state = .speaking }
        }
    }

    /// 文字 / 状态更新（applicationContext）
    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            // ASR 实时文字
            if let t = applicationContext["asrText"] as? String, !t.isEmpty {
                self.asrText = t
            }
            // AI 回复文字（每句追加）
            if let t = applicationContext["replyText"] as? String, !t.isEmpty {
                self.replyText += t
                if self.state != .speaking { self.state = .speaking }
            }
            // 会话结束信号
            if let s = applicationContext["sessionState"] as? String, s == "ended" {
                self.turnCount += 1
                self.state = .idle
            }
            // 错误信号
            if let errMsg = applicationContext["errorMessage"] as? String {
                self.state = .error(errMsg)
            }
        }
    }
}
