// WatchAudioEngine.swift
// Apple Watch 侧：
//   1. 使用 AVAudioEngine 捕获麦克风音频并转换为 PCM Int16 LE @ 16kHz
//   2. 内置 VAD（Voice Activity Detection）静音检测，自动停止录音
//   3. 使用 AVAudioPlayerNode 播放 iPhone 回传的 TTS PCM 音频

import Foundation
import AVFoundation
import WatchKit

// MARK: - PCM 格式常量

private let kUpstreamSampleRate   = 16000.0
private let kDownstreamSampleRate = 24000.0

// MARK: - VAD 配置

private struct VADConfig {
    /// RMS 低于此值视为静音（可根据环境调整，0~32767）
    static let silenceThreshold: Float = 150.0
    /// 连续静音帧数超过此值触发自动停止（100ms/帧 × 15 = 1.5s）
    static let silenceFrameLimit = 15
    /// 最少录音帧数，防止误触（100ms/帧 × 8 = 0.8s）
    static let minSpeakingFrames = 8
}

// MARK: - WatchAudioEngine

final class WatchAudioEngine: NSObject, ObservableObject {

    // 回调：每捕获一块 PCM 就回调（已转为 16kHz Int16 LE）
    var onPCMChunk: ((Data) -> Void)?
    /// VAD 检测到用户停止说话时触发（自动结束录音）
    var onSpeechEnded: (() -> Void)?

    // 当前状态
    @Published var isRecording  = false
    @Published var isPlaying    = false
    @Published var currentRMS: Float = 0  // 供 UI 波形动画使用

    // AVAudioEngine（录音）
    private let recordEngine   = AVAudioEngine()
    private var inputNode: AVAudioInputNode { recordEngine.inputNode }

    // AVAudioEngine（播放）
    private let playEngine     = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()

    // 播放队列缓冲
    private var ttsQueue: [AVAudioPCMBuffer] = []
    private var isSyncPlaying = false

    // VAD 状态
    private var silenceCounter   = 0
    private var speakingFrames   = 0
    private var hasSpeechStarted = false  // 至少检测到一次有效语音才启用静音计数

    override init() {
        super.init()
        setupPlayEngine()
    }

    // MARK: - 录音（含 VAD）

    func startRecording() {
        guard !isRecording else { return }

        configureAudioSession()
        resetVAD()

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: kUpstreamSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            print("[AudioEngine] failed to create target format"); return
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            print("[AudioEngine] failed to create converter"); return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) {
            [weak self] buffer, _ in
            guard let self = self else { return }

            // ---- 重采样 ----
            let targetFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * kUpstreamSampleRate / nativeFormat.sampleRate
            )
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: targetFrameCount
            ) else { return }

            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            guard error == nil,
                  let int16Data = convertedBuffer.int16ChannelData else { return }

            let frameLen  = Int(convertedBuffer.frameLength)
            let byteCount = frameLen * 2
            let pcmData   = Data(bytes: int16Data[0], count: byteCount)

            // ---- VAD：计算 RMS ----
            let rms = self.computeRMS(int16Data[0], count: frameLen)
            DispatchQueue.main.async { self.currentRMS = rms }

            if rms > VADConfig.silenceThreshold {
                // 有效语音帧
                self.hasSpeechStarted = true
                self.silenceCounter   = 0
                self.speakingFrames  += 1
            } else if self.hasSpeechStarted {
                // 已经说过话了，现在是静音
                self.silenceCounter += 1
                if self.silenceCounter >= VADConfig.silenceFrameLimit
                    && self.speakingFrames >= VADConfig.minSpeakingFrames {
                    // 触发自动停止
                    DispatchQueue.main.async {
                        self.stopRecording()
                        self.onSpeechEnded?()
                    }
                    return
                }
            }

            // ---- 回调 PCM ----
            DispatchQueue.main.async {
                self.onPCMChunk?(pcmData)
            }
        }

        do {
            try recordEngine.start()
            isRecording = true
        } catch {
            print("[AudioEngine] start failed: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        inputNode.removeTap(onBus: 0)
        recordEngine.stop()
        isRecording  = false
        currentRMS   = 0
        resetVAD()
    }

    // MARK: - 播放 TTS

    /// 将 iPhone 回传的 PCM 数据入队播放（pcm_s16le @ 24kHz mono）
    func enqueueAudio(_ pcmData: Data) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: kDownstreamSampleRate,
            channels: 1,
            interleaved: true
        ) else { return }

        let frameCount = pcmData.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcmData.withUnsafeBytes { ptr in
            if let dest = buffer.int16ChannelData?[0] {
                memcpy(dest, ptr.baseAddress!, pcmData.count)
            }
        }

        ttsQueue.append(buffer)
        if !isSyncPlaying { drainQueue() }
    }

    private func drainQueue() {
        guard !ttsQueue.isEmpty else {
            isSyncPlaying = false
            DispatchQueue.main.async { self.isPlaying = false }
            return
        }
        isSyncPlaying = true
        DispatchQueue.main.async { self.isPlaying = true }

        let buffer = ttsQueue.removeFirst()
        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.drainQueue()
        }
        if !playerNode.isPlaying { playerNode.play() }
    }

    func stopPlaying() {
        playerNode.stop()
        ttsQueue.removeAll()
        isSyncPlaying = false
        DispatchQueue.main.async { self.isPlaying = false }
    }

    // MARK: - 私有：配置播放引擎

    private func setupPlayEngine() {
        playEngine.attach(playerNode)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: kDownstreamSampleRate,
            channels: 1,
            interleaved: true
        ) else { return }
        playEngine.connect(playerNode, to: playEngine.mainMixerNode, format: format)
        try? playEngine.start()
    }

    // MARK: - 私有：音频会话

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // watchOS 不支持 defaultToSpeaker，旧系统也不支持 allowBluetooth。
        if #available(watchOS 11.0, *) {
            try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        } else {
            try? session.setCategory(.playAndRecord, mode: .voiceChat)
        }
        try? session.setActive(true)
    }

    // MARK: - 私有：VAD 工具

    private func resetVAD() {
        silenceCounter   = 0
        speakingFrames   = 0
        hasSpeechStarted = false
    }

    /// 计算 Int16 样本的 RMS（均方根）音量
    private func computeRMS(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sumSquares: Float = 0
        for i in 0..<count {
            let s = Float(samples[i])
            sumSquares += s * s
        }
        return sqrt(sumSquares / Float(count))
    }
}
