# SimpleMouseGesture (macOS)

右クリック + ドラッグでブラウズ操作やウィンドウ操作を行う、軽量メニューバーアプリ。

- ← 戻る（⌘+[）
- → 進む（⌘+]）
- ↖ タブを閉じる（⌘+W）
- ↗︎ タブを追加（⌘+T）
- ↑ Mission Control 起動

## 必要な権限
- システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可
- （必要なら）同 > バックグラウンド項目 で許可
- ログイン時に起動：一般 > ログイン項目 でオン

## 対応環境
- macOS 26+ / Xcode 26+

## ジェスチャーの変更
- 以下のコードを自分好みのものに編集してください
    - private func handleEvent > case .rightMouseUp:
    - private func handleEvent > case .otherMouseUp:

## ビルド
1. リポジトリを clone して `SimpleMouseGesture.xcodeproj` を Xcode で開く
2. Targets > SimpleMouseGesture / SimpleMouseGestureLoginItem の両方で
   Signing & Capabilities の Team を自分のチームに設定（Automatic Signing 推奨）
3. 両ターゲットの Bundle Identifier を一意の値に変更
   例）com.yourdomain.SimpleMouseGesture / com.yourdomain.SimpleMouseGesture.LoginItem
4. Scheme を SimpleMouseGesture にして ⌘R で実行
   ※ 初回は「アクセシビリティ」の許可ダイアログが出たら許可してください


## ライセンス
MIT (c) 2025 Nikumaru
