import SwiftUI
import AppKit

@main
struct SimpleMouseGestureLoginItemApp: App {
    var body: some Scene {
        // 目に見えるウインドウは出さない
        WindowGroup {
            EmptyView()
                .frame(width: 1, height: 1)
                .onAppear {
                    launchMainAppAndQuit()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }

    private func launchMainAppAndQuit() {
        // メインアプリの Bundle ID に置き換えてください
        let mainAppBundleID = "com.nikumaru.SimpleMouseGesture"

        // Bundle ID からアプリの URL を取得し、推奨 API で起動
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mainAppBundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false // メインアプリを前面に
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
                NSApp.terminate(nil)
            }
        } else {
            // URL が見つからない場合はそのまま終了
            NSApp.terminate(nil)
        }
    }
}
