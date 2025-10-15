import Foundation
import ServiceManagement

/// macOS 13+ の SMAppService を用いたログイン時起動の管理
/// 注意: 有効化には "Login Item" ターゲット（ヘルパーアプリ）の追加と、
/// その Bundle Identifier を `helperBundleIdentifier` に設定する必要があります。
///
/// 例: com.example.SimpleMouseGesture.LoginItemHelper
final class LoginItemManager: ObservableObject {
    // TODO: あなたの Login Item ヘルパーの Bundle ID に置き換えてください
    private let helperBundleIdentifier = "com.nikumaru.SimpleMouseGestureLoginItem"

    @Published private(set) var isEnabled: Bool = false

    private var appService: SMAppService? {
        SMAppService.loginItem(identifier: helperBundleIdentifier)
    }

    init() {
        refresh()
    }

    /// 現在の有効/無効状態を読み直します。
    func refresh() {
        guard let appService = appService else {
            isEnabled = false
            return
        }
        isEnabled = appService.status == .enabled
    }

    /// ログイン時起動を切り替えます。
    func setEnabled(_ enable: Bool) {
        guard let appService = appService else {
            print("[LoginItemManager] appService is nil for identifier: \(helperBundleIdentifier)")
            return
        }
        do {
            if enable {
                try appService.register()
                print("[LoginItemManager] register() succeeded. status=\(appService.status.rawValue)")
            } else {
                try appService.unregister()
                print("[LoginItemManager] unregister() succeeded. status=\(appService.status.rawValue)")
            }
            refresh()
        } catch {
            // Keep UI state in sync even on failure
            refresh()
            print("[LoginItemManager] Failed to set enabled=\(enable)")
            print("  identifier: \(helperBundleIdentifier)")
            print("  status: \(appService.status.rawValue)")
            print("  error: \(error)")
        }
    }
}
