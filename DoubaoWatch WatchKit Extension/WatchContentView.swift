// WatchContentView.swift
// Apple Watch 主 UI：极简设计，适配小屏幕
// 特性：VAD 实时音量波形 / 多轮对话轮次显示 / 状态动画

import SwiftUI

struct WatchContentView: View {
    @StateObject private var vm = WatchViewModel()

    var body: some View {
        ZStack {
            // 动态背景
            LinearGradient(
                colors: backgroundColors(for: vm.state),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: vm.state)

            VStack(spacing: 6) {

                // ── 顶部：轮次 + 状态图标 ──
                HStack {
                    if vm.turnCount > 0 {
                        Label("\(vm.turnCount)轮", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    stateLabel(vm.state)
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)

                // ── 中部：状态动画 / 波形 ──
                centerContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── 下部：文字显示 ──
                textPanel

                // ── 底部：主按钮 ──
                micButton
                    .padding(.bottom, 4)
            }
        }
    }

    // MARK: - 中部内容

    @ViewBuilder
    private var centerContent: some View {
        switch vm.state {
        case .idle:
            VStack(spacing: 4) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Xiaolan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("点击麦克风开始")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }

        case .connecting:
            VStack(spacing: 6) {
                ProgressView().tint(.white)
                Text("连接中…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }

        case .listening:
            VStack(spacing: 4) {
                // 根据实时 RMS 驱动波形
                RealtimeWaveformView(rms: vm.audioEngine.currentRMS)
                    .frame(height: 32)
                Text("在听…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
                // VAD 静音倒计时提示（安静时变淡）
                if vm.audioEngine.currentRMS < 150 {
                    Text("请说话").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.audioEngine.currentRMS)

        case .thinking:
            VStack(spacing: 6) {
                ThinkingDotsView()
                Text("思考中…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            }

        case .speaking:
            VStack(spacing: 6) {
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating)
                Text("回复中").font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
            }

        case .error(let msg):
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 22))
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - 文字面板

    @ViewBuilder
    private var textPanel: some View {
        if !vm.asrText.isEmpty || !vm.replyText.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if !vm.asrText.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 1)
                        Text(vm.asrText)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }
                if !vm.replyText.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 8))
                            .foregroundStyle(.cyan)
                            .padding(.top, 1)
                        Text(vm.replyText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(4)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 麦克风按钮

    private var micButton: some View {
        Button(action: vm.handleMicButton) {
            ZStack {
                Circle()
                    .fill(buttonColor(for: vm.state))
                    .frame(width: 46, height: 46)
                    .shadow(color: buttonColor(for: vm.state).opacity(0.5), radius: 8)
                Image(systemName: buttonIcon(for: vm.state))
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive(vm.state) ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: vm.state)
    }

    // MARK: - 状态标签

    @ViewBuilder
    private func stateLabel(_ state: ConversationState) -> some View {
        switch state {
        case .listening:
            Label("录音", systemImage: "record.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.red.opacity(0.9))
        case .speaking:
            Label("播放", systemImage: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.9))
        case .thinking:
            Label("思考", systemImage: "ellipsis.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.orange.opacity(0.9))
        default:
            EmptyView()
        }
    }

    // MARK: - 工具方法

    private func buttonIcon(for state: ConversationState) -> String {
        switch state {
        case .idle:       return "mic.fill"
        case .connecting: return "ellipsis"
        case .listening:  return "stop.fill"
        case .thinking:   return "xmark"
        case .speaking:   return "hand.raised.fill"
        case .error:      return "arrow.clockwise"
        }
    }

    private func buttonColor(for state: ConversationState) -> Color {
        switch state {
        case .idle:       return .blue
        case .connecting: return .gray
        case .listening:  return .red
        case .thinking:   return .orange
        case .speaking:   return .purple
        case .error:      return .gray
        }
    }

    private func backgroundColors(for state: ConversationState) -> [Color] {
        switch state {
        case .listening: return [.init(red: 0.12, green: 0.05, blue: 0.25), .init(red: 0.2, green: 0.0, blue: 0.15)]
        case .speaking:  return [.init(red: 0.05, green: 0.1, blue: 0.3), .init(red: 0.0, green: 0.05, blue: 0.25)]
        case .thinking:  return [.init(red: 0.18, green: 0.1, blue: 0.0), .init(red: 0.12, green: 0.08, blue: 0.0)]
        default:         return [.init(red: 0.05, green: 0.05, blue: 0.15), .black]
        }
    }

    private func isActive(_ state: ConversationState) -> Bool {
        switch state {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }
}

// MARK: - 实时音量波形（由 VAD RMS 驱动）

struct RealtimeWaveformView: View {
    let rms: Float
    private let barCount = 7

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(index: i))
                    .frame(width: 4, height: barHeight(index: i))
                    .animation(.easeInOut(duration: 0.1), value: rms)
            }
        }
    }

    private func barHeight(index: Int) -> CGFloat {
        // 中间高、两侧低的包络 × RMS 音量
        let envelope: [Float] = [0.4, 0.6, 0.85, 1.0, 0.85, 0.6, 0.4]
        let normalized = min(Float(rms) / 2000.0, 1.0)
        let base: Float = 4.0
        let maxH: Float = 30.0
        return CGFloat(base + (maxH - base) * envelope[index] * (0.2 + normalized * 0.8))
    }

    private func barColor(index: Int) -> Color {
        let normalized = min(rms / 2000.0, 1.0)
        return normalized > 0.3 ? .white : .white.opacity(0.4)
    }
}

// MARK: - 思考中三点动画

struct ThinkingDotsView: View {
    @State private var scales: [CGFloat] = [1, 1, 1]
    @State private var activeIdx = 0
    let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .scaleEffect(scales[i])
                    .animation(.spring(response: 0.25), value: scales[i])
            }
        }
        .onReceive(timer) { _ in
            var s: [CGFloat] = [0.55, 0.55, 0.55]
            s[activeIdx] = 1.35
            scales = s
            activeIdx = (activeIdx + 1) % 3
        }
    }
}
