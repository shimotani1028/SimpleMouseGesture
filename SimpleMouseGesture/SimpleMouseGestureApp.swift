import SwiftUI
import AppKit

@main
struct SimpleMouseGestureApp: App {
    // AppKit の AppDelegate を SwiftUI アプリに紐づける（既存の処理がある前提）
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // ログイン項目（自動起動）管理
    @StateObject private var loginItemManager = LoginItemManager()

    var body: some Scene {
        // メニューバー常駐（macOS 13+）
        MenuBarExtra("SimpleMouseGesture", systemImage: "cursor.rays") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SimpleMouseGesture")
                    .font(.title)
                    .bold()


                
                
                Text("右クリックを押しながら…")
                Text("・左 ← にドラッグ：戻る（⌘+←）")
                Text("・右 → にドラッグ：進む（⌘+→）")
                Text("・左上 ↖ にドラッグ：タブを閉じる（⌘+W）")
                Text("・右上 ↗︎ にドラッグ：タブを追加（⌘+T）")
                Text("・上 ↑ にドラッグ：Mission Control起動")
                
                
                Text("初回は「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で本アプリを許可してください。")
                    .font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                
                Divider()
                    .padding(.vertical, 8)

                Toggle("ログイン時に起動", isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { loginItemManager.setEnabled($0) }
                ))
                .toggleStyle(.switch)

                
                Text("ログイン時に起動を有効にするには「システム設定 > 一般 > ログイン項目」で本アプリをオンにしてください。また、初回は「システム設定 > プライバシーとセキュリティ > バックグラウンド項目」で許可が必要な場合があります。")
                    .font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                
                Divider()



                
                Button("アプリの終了") {
                    NSApp.terminate(nil)
                }
            }
            .padding(20)
            .frame(minWidth: 560)
            .onAppear { loginItemManager.refresh() }
        }
        .menuBarExtraStyle(.window) // ← これを追加
        // Dock アイコンを非表示にするには、Info.plist に LSUIElement = YES を設定してください。
        // 例: Application is agent (UIElement) を YES

        // 必要に応じて通常のウインドウを併設したい場合は、以下を復活
        // WindowGroup { ContentView() }
    }
}
