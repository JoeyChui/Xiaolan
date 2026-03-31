// DoubaoRealtimeClient.swift
// iPhone 侧：负责与豆包端到端实时语音 RealtimeAPI 建立 WebSocket 连接
// 支持多轮对话上下文（ConversationCreated / ConversationRetrieved）
// 文档：https://www.volcengine.com/docs/6561/1594356

import Foundation
import AVFoundation
import Combine

// MARK: - 配置

struct DoubaoConfig {
    // ⚠️ 请在此填入你的火山引擎鉴权信息
    static let appID     = "YOUR_APP_ID"
    static let accessKey = "YOUR_ACCESS_KEY"
    static let appKey    = "YOUR_APP_KEY"

    // 模型版本：1.2.1.1 = O版本，1.2.2.2 = O2.0版本
    static let modelVersion = "1.2.2.2"

    // 音色（O/O2.0版本支持）
    // zh_female_vv_jupiter_bigtts / zh_female_xiaohe_jupiter_bigtts
    // zh_male_yunzhou_jupiter_bigtts / zh_male_xiaotian_jupiter_bigtts
    static let speaker = "zh_female_vv_jupiter_bigtts"

    // WebSocket 接入点
    static let wsURL = "wss://openspeech.bytedance.com/api/v3/realtime/dialogue"

    // 上行音频格式
    static let upstreamSampleRate = 16000
    static let upstreamChannels   = 1

    // 下行音频格式（pcm_s16le，Watch 直接播放）
    static let downstreamFormat     = "pcm_s16le"
    static let downstreamSampleRate = 24000
    static let downstreamChannels   = 1

    // System Prompt
    static let systemRole = """
    你是一个简洁、友善的语音助手，运行在 Apple Watch 上。
    回答请保持简短（不超过 50 字），因为用户在手腕上看文字和听语音。
    """
    static let speakingStyle = "简洁友好"
    static let botName       = "豆包助手"
}

// MARK: - 事件类型常量

private enum ClientEvent: UInt32 {
    case startSession       = 100
    case finishSession      = 102
    case finishConnection   = 105
    case taskRequest        = 200   // 发送 PCM 音频
    case chatTextQuery      = 551   // 发送文字输入
    // 多轮对话上下文管理
    case createConversation  = 561
    case updateConversation  = 562
    case retrieveConversation = 563
    case deleteConversation  = 565
}

private enum ServerEvent: Int {
    case sessionStarted     = 50
    case asrInfo            = 501
    case asrResponse        = 502
    case asrEnded           = 503
    case ttsResponse        = 400
    case ttsSentenceStart   = 401
    case ttsSentenceEnd     = 402
    case ttsEnded           = 403
    case chatEnded          = 559
    case conversationCreated   = 567
    case conversationRetrieved = 569
    case conversationDeleted   = 571
    case dialogError        = 599
}

// MARK: - 多轮对话 Item

struct ConversationItem: Codable {
    let itemId:    String
    let role:      String   // "user" / "assistant"
    let text:      String
    let timestamp: Int

    enum CodingKeys: String, CodingKey {
        case itemId   = "item_id"
        case role, text, timestamp
    }
}

// MARK: - DoubaoRealtimeClient

final class DoubaoRealtimeClient: NSObject, ObservableObject {

    // 对外状态
    @Published var isConnected:    Bool   = false
    @Published var isListening:    Bool   = false
    @Published var latestASR:      String = ""
    @Published var latestReply:    String = ""
    @Published var errorMessage:   String?
    /// 当前会话保存的多轮上下文
    @Published var conversationHistory: [ConversationItem] = []

    // 回调
    var onAudioChunk:    ((Data) -> Void)?
    var onASRText:       ((String) -> Void)?
    var onReplyText:     ((String) -> Void)?
    var onSessionEnded:  (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var sessionID   = ""
    private var isSessionStarted = false

    // 多轮上下文：每轮结束后把 user+assistant 文字存入
    private var pendingUserText      = ""  // 本轮 ASR 结果
    private var pendingAssistantText = ""  // 本轮 AI 回复
    private var replyChunks: [String] = []

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - 公开接口

    func connect() {
        guard !isConnected else { return }
        guard let url = URL(string: DoubaoConfig.wsURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer; \(DoubaoConfig.accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue(DoubaoConfig.appID, forHTTPHeaderField: "X-App-Id")

        webSocketTask = urlSession.webSocketTask(with: request)
        webSocketTask?.resume()
        startReceiving()
    }

    func sendAudio(_ pcmData: Data) {
        guard isSessionStarted else { return }
        sendBinaryMessage(eventID: ClientEvent.taskRequest.rawValue,
                          flags: 0x04,
                          payload: pcmData)
    }

    func sendTextQuery(_ text: String) {
        guard isSessionStarted else { return }
        sendJSONMessage(eventID: ClientEvent.chatTextQuery.rawValue,
                        body: ["text": text])
    }

    func finishSession() {
        guard isSessionStarted else { return }
        isListening = false
        sendJSONMessage(eventID: ClientEvent.finishSession.rawValue, body: [:])
        isSessionStarted = false
    }

    func disconnect() {
        finishSession()
        sendJSONMessage(eventID: ClientEvent.finishConnection.rawValue, body: [:])
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        sessionID   = ""
    }

    // MARK: - 多轮对话：上下文管理

    /// 将历史对话注入当前会话（在 StartSession 之后调用）
    func injectConversationHistory(_ items: [[String: Any]]) {
        guard isSessionStarted else { return }
        let body: [String: Any] = ["items": items]
        sendJSONMessage(eventID: ClientEvent.createConversation.rawValue, body: body)
    }

    /// 清空服务端上下文
    func clearConversationHistory() {
        guard isSessionStarted else { return }
        sendJSONMessage(eventID: ClientEvent.deleteConversation.rawValue, body: [:])
        DispatchQueue.main.async { self.conversationHistory = [] }
    }

    // MARK: - 私有：构建历史上下文（把已存的 conversationHistory 注入）

    private func pushExistingHistoryIfNeeded() {
        guard !conversationHistory.isEmpty else { return }
        let items: [[String: Any]] = conversationHistory.map { item in
            [
                "item_id": item.itemId,
                "role":    item.role,
                "text":    item.text
            ]
        }
        injectConversationHistory(items)
    }

    // MARK: - 私有：发送消息

    private func sendJSONMessage(eventID: UInt32, flags: UInt8 = 0x00, body: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        let message = buildMessage(eventID: eventID, messageType: 0x10,
                                   serialMethod: 0x20, flags: flags, payload: jsonData)
        webSocketTask?.send(.data(message)) { err in
            if let e = err { print("[DoubaoClient] send error: \(e)") }
        }
    }

    private func sendBinaryMessage(eventID: UInt32, flags: UInt8, payload: Data) {
        let message = buildMessage(eventID: eventID, messageType: 0x10,
                                   serialMethod: 0x00, flags: flags, payload: payload)
        webSocketTask?.send(.data(message)) { err in
            if let e = err { print("[DoubaoClient] audio send error: \(e)") }
        }
    }

    /// 组装豆包二进制消息帧
    private func buildMessage(eventID: UInt32, messageType: UInt8,
                               serialMethod: UInt8, flags: UInt8,
                               payload: Data) -> Data {
        var data = Data()
        let sidData    = sessionID.data(using: .utf8) ?? Data()
        let sidLen     = UInt32(sidData.count)
        let payloadLen = UInt32(payload.count)

        // 协议头 4 bytes
        data.append(0x11)          // protocol_version
        data.append(0x11)          // header_size
        data.append(messageType)
        data.append(flags)
        // 序列化/压缩 4 bytes
        data.append(serialMethod)
        data.append(0x00)          // no compression
        data.append(0x00)
        data.append(0x00)
        // event_id 4 bytes (big-endian)
        data.append(contentsOf: withUnsafeBytes(of: eventID.bigEndian, Array.init))
        // session_id
        data.append(contentsOf: withUnsafeBytes(of: sidLen.bigEndian, Array.init))
        data.append(sidData)
        // payload
        data.append(contentsOf: withUnsafeBytes(of: payloadLen.bigEndian, Array.init))
        data.append(payload)
        return data
    }

    // MARK: - 私有：接收

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if case .data(let d) = msg { self.handleServerMessage(d) }
                self.startReceiving()
            case .failure(let err):
                DispatchQueue.main.async {
                    self.isConnected  = false
                    self.errorMessage = err.localizedDescription
                    self.onSessionEnded?()
                }
            }
        }
    }

    private func handleServerMessage(_ data: Data) {
        guard data.count >= 16 else { return }
        var offset = 0
        offset += 4  // 跳过协议头

        let serializeType = data[offset + 1]   // index 5
        offset += 4

        // event_id
        let eventIDRaw = data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4

        // session_id
        let sidLen = data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4
        if sidLen > 0, offset + Int(sidLen) <= data.count {
            sessionID = String(data: data.subdata(in: offset..<(offset + Int(sidLen))),
                               encoding: .utf8) ?? sessionID
        }
        offset += Int(sidLen)

        guard offset + 4 <= data.count else { return }
        let payloadLen = data.subdata(in: offset..<(offset + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        offset += 4

        let payloadEnd = offset + Int(payloadLen)
        guard payloadEnd <= data.count else { return }
        let payload = data.subdata(in: offset..<payloadEnd)

        if serializeType == 0x20 {
            handleJSONEvent(eventID: eventIDRaw, payload: payload)
        } else {
            handleBinaryEvent(eventID: eventIDRaw, payload: payload)
        }
    }

    private func handleJSONEvent(eventID: UInt32, payload: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }

        switch ServerEvent(rawValue: Int(eventID)) {

        case .sessionStarted:
            print("[DoubaoClient] session started id=\(sessionID)")
            isSessionStarted = true
            DispatchQueue.main.async { self.isConnected = true }
            sendStartSession()
            // 注入已有的多轮历史
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.pushExistingHistoryIfNeeded()
            }

        case .asrInfo:
            if let t = json["asr_text"] as? String {
                DispatchQueue.main.async { self.latestASR = t; self.onASRText?(t) }
            }

        case .asrResponse:
            if let t = json["asr_text"] as? String {
                pendingUserText = t
                DispatchQueue.main.async { self.latestASR = t }
            }

        case .asrEnded:
            print("[DoubaoClient] ASR ended")

        case .ttsSentenceStart:
            replyChunks = []
            if let t = json["text"] as? String { replyChunks.append(t) }

        case .ttsSentenceEnd:
            let sentence = replyChunks.joined()
            pendingAssistantText += sentence
            DispatchQueue.main.async { self.latestReply = self.pendingAssistantText; self.onReplyText?(sentence) }

        case .ttsEnded:
            print("[DoubaoClient] TTS ended")

        case .chatEnded:
            // 本轮对话结束 → 保存到本地历史
            appendToLocalHistory()
            DispatchQueue.main.async {
                self.isListening = false
                self.onSessionEnded?()
            }

        case .conversationCreated:
            if let items = json["items"] as? [[String: Any]] {
                let decoded = items.compactMap { decode(item: $0) }
                DispatchQueue.main.async { self.conversationHistory = decoded }
            }
            print("[DoubaoClient] conversation context injected (\(conversationHistory.count) items)")

        case .conversationRetrieved:
            if let items = json["items"] as? [[String: Any]] {
                let decoded = items.compactMap { decode(item: $0) }
                DispatchQueue.main.async { self.conversationHistory = decoded }
            }

        case .dialogError:
            let code = json["status_code"] as? Int ?? 0
            let msg  = json["message"] as? String ?? "unknown error"
            DispatchQueue.main.async { self.errorMessage = "[\(code)] \(msg)" }

        default:
            break
        }
    }

    private func handleBinaryEvent(eventID: UInt32, payload: Data) {
        if ServerEvent(rawValue: Int(eventID)) == .ttsResponse {
            DispatchQueue.main.async { self.onAudioChunk?(payload) }
        }
    }

    // MARK: - 私有：StartSession

    private func sendStartSession() {
        let body: [String: Any] = [
            "dialog": [
                "extra": [
                    "model": DoubaoConfig.modelVersion
                ]
            ],
            "asr": [
                "audio_info": [
                    "format":      "pcm",
                    "sample_rate": DoubaoConfig.upstreamSampleRate,
                    "channel":     DoubaoConfig.upstreamChannels,
                    "bit":         16
                ],
                "extra": [:]
            ],
            "tts": [
                "speaker": DoubaoConfig.speaker,
                "audio_config": [
                    "channel":     DoubaoConfig.downstreamChannels,
                    "format":      DoubaoConfig.downstreamFormat,
                    "sample_rate": DoubaoConfig.downstreamSampleRate
                ],
                "extra": [:]
            ],
            "bot_name":      DoubaoConfig.botName,
            "system_role":   DoubaoConfig.systemRole,
            "speaking_style": DoubaoConfig.speakingStyle
        ]
        sendJSONMessage(eventID: ClientEvent.startSession.rawValue, body: body)
        DispatchQueue.main.async { self.isListening = true }
    }

    // MARK: - 私有：多轮历史管理

    private func appendToLocalHistory() {
        let now = Int(Date().timeIntervalSince1970)
        var newItems = conversationHistory

        if !pendingUserText.isEmpty {
            newItems.append(ConversationItem(
                itemId:    "u_\(now)",
                role:      "user",
                text:      pendingUserText,
                timestamp: now
            ))
        }
        if !pendingAssistantText.isEmpty {
            newItems.append(ConversationItem(
                itemId:    "a_\(now)",
                role:      "assistant",
                text:      pendingAssistantText,
                timestamp: now
            ))
        }
        // 最多保留最近 20 条，避免 token 超限
        if newItems.count > 20 { newItems = Array(newItems.suffix(20)) }

        DispatchQueue.main.async { self.conversationHistory = newItems }
        pendingUserText      = ""
        pendingAssistantText = ""
        replyChunks          = []
    }

    private func decode(item: [String: Any]) -> ConversationItem? {
        guard let id   = item["item_id"]  as? String,
              let role = item["role"]     as? String,
              let text = item["text"]     as? String else { return nil }
        let ts = item["timestamp"] as? Int ?? 0
        return ConversationItem(itemId: id, role: role, text: text, timestamp: ts)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DoubaoRealtimeClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        print("[DoubaoClient] WebSocket opened")
    }
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        print("[DoubaoClient] WebSocket closed: \(closeCode)")
        DispatchQueue.main.async {
            self.isConnected = false
            self.isListening = false
        }
    }
}
