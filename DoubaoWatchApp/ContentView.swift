// ContentView.swift
// iPhone 配套 App 界面（保持后台运行，作为 Watch 的 WebSocket 代理）

import SwiftUI

struct ContentView: View {
    @StateObject private var watchManager = WatchSessionManager.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Xiaolan")
                .font(.title.bold())

            Text("请保持此 App 在前台或后台运行\n以便 Apple Watch 通过它连接豆包语音 AI")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider()

            HStack {
                Circle()
                    .fill(watchManager.watchIsReachable ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(watchManager.watchIsReachable ? "Watch 已连接" : "Watch 未连接")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Text("在 Apple Watch 上点击麦克风按钮开始对话")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .onAppear {
            // 确保 WatchSessionManager 已初始化
            _ = WatchSessionManager.shared
        }
    }
}
