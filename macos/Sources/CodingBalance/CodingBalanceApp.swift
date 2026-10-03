import AppKit
import SwiftUI

@main
struct CodingBalanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // 菜单栏状态项由 AppState 用 AppKit NSStatusItem 创建（最稳定）
        // 此处仅保留「管理账户」设置窗口
        Window("管理账户", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}

/// 菜单栏应用：不显示 Dock 图标
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 菜单栏常驻应用：关闭「管理账户」窗口后不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
