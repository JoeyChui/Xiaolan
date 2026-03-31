// WatchSessionManager.swift
// iPhone 侧：通过 WatchConnectivity 与 Apple Watch 互传数据
// Watch → iPhone: PCM 音频块（Data）+ 控制指令（String）
// iPhone → Watch: TTS PCM 音频块（Data）+ 识别/回复文字（ApplicationContext）

import Foundation
import WatchConnectivity
import Combine

final class WatchSessionManager: NSObject, ObservableObject {

    static let shared = WatchSessionManager()

    @Published var watchIsReachable = false

    private let doubaoClient = DoubaoRealtimeClient()
    private var cancellables = Set<AnyCancellable>()

    // Watch 发来的 PCM 缓冲（累积到一定大小再转发 API 减少调用次数）
    private var audioPCMBuffer = Data()
    private let audioFlushSize = 3200  // 约 100ms @ 16kHz 16bit mono

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        setupDoubaoCallbacks()
    }

    // MARK: - 豆包客户端回调

    private func setupDoubaoCallbacks() {
        // TTS 音频 → 发给 Watch
        doubaoClient.onAudioChunk = { [weak self] pcmData in
            self?.sendToWatch(data: pcmData, key: "ttsAudio")
        }

        // ASR 识别文字 → 发给 Watch
        doubaoClient.onASRText = { [weak self] text in
            self?.sendContextToWatch(["asrText": text])
        }

        // AI 回复文字 → 发给 Watch
        doubaoClient.onReplyText = { [weak self] text in
            self?.sendContextToWatch(["replyText": text])
        }

        // 会话结束
        doubaoClient.onSessionEnded = { [weak self] in
            self?.sendContextToWatch(["sessionState": "ended"])
        }
    }

    // MARK: - 向 Watch 发送数据

    private func sendToWatch(data: Data, key: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessageData(data, replyHandler: nil) { error in
            print("[WatchSession] sendData error: \(error)")
        }
    }

    private func sendContextToWatch(_ context: [String: Any]) {
        try? WCSession.default.updateApplicationContext(context)
    }

    // MARK: - 控制 DoubaoClient

    func startSession() {
        doubaoClient.connect()
    }

    func stopSession() {
        doubaoClient.finishSession()
    }
}

// MARK: - WCSessionDelegate (iPhone 侧)

extension WatchSessionManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        print("[WatchSession] activated: \(activationState.rawValue), error: \(String(describing: error))")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.watchIsReachable = session.isReachable
        }
    }

    /// 收到 Watch 发来的 Data（PCM 音频块）
    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        audioPCMBuffer.append(messageData)
        if audioPCMBuffer.count >= audioFlushSize {
            let chunk = audioPCMBuffer
            audioPCMBuffer = Data()
            doubaoClient.sendAudio(chunk)
        }
    }

    /// 收到 Watch 发来的 Message（控制指令）
    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any]) {
        if let cmd = message["cmd"] as? String {
            switch cmd {
            case "start":
                startSession()
            case "stop":
                stopSession()
            default:
                break
            }
        }
    }
}
