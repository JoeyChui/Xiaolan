// App.swift - iPhone App 入口

import SwiftUI

@main
struct DoubaoWatchApp: App {
    // 在 App 启动时就初始化 WatchSessionManager，确保 WC 激活
    @StateObject private var watchManager = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(watchManager)
        }
    }
}
