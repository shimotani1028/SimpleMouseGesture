//
// SimpleMouseGesture（右クリック＋移動で操作する軽量ジェスチャー）
//
// できること
//   ・右ドラッグ ←  :  戻る（⌘+[ と ⌘+← を送る）
//   ・右ドラッグ →  :  進む（⌘+] と ⌘+→ を送る）
//   ・右ドラッグ ↖  :  タブを閉じる（⌘+W）など
//
// 重要ポイント
//   ・「アクセシビリティ」権限が必要（イベント監視・疑似キー送信のため）
//   ・右クリックの“自然な挙動”（メニュー表示）は壊さない方針
//   ・ジェスチャー中の軌跡は最前面・クリック透過の透明ウインドウに描く
//

/*
 初心者向けガイド：このファイル（AppDelegate.swift）の役割と全体像
 
 ・このアプリは「右クリック＋ドラッグ」の簡単なジェスチャーをOS全体で監視し、
   方向に応じてキーボードショートカットを“擬似的に”送るユーティリティです。
 ・このファイル AppDelegate.swift がアプリの中心で、以下の役割を担います：
   1) アクセシビリティ権限の確認（イベント監視・疑似キー送信に必要）
   2) CGEventTap（イベントタップ）で OS の右クリック関連イベントを購読
   3) 右ドラッグ量から方向を判定して、対応するショートカットを送信
   4) ジェスチャー中の軌跡（線）を透明な最前面ウインドウに描画
 
 ファイル内の主なブロック：
   - アプリライフサイクル（起動・終了）
   - イベントタップのセットアップ／イベント処理（handleEvent）
   - キー送信のユーティリティ（postCommandCharacter / postControlCharacter など）
   - 軌跡描画用のオーバーレイ（StrokeOverlayView とウインドウ管理）
   - 補助機能（最前面アプリ取得、Mission Control 起動など）
*/

import Cocoa
import ApplicationServices           // AX 権限と CGEvent 用
import Carbon.HIToolbox             // キーコード (kVK_ANSI_W など)
import Carbon
/// アプリのメインクラス。起動時に「グローバルイベント（CGEvent）」を購読し、
/// 右クリックのドラッグ量（押下点からの dx, dy）で簡単なジェスチャーを判定して
/// 対応するキーボードショートカットを“擬似的に”送ります。右クリックの通常メニューは維持します。
class AppDelegate: NSObject, NSApplicationDelegate {

    // Event tap and run loop source used to monitor global mouse events
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Application lifecycle
    /// アプリ起動時の初期化手順（ざっくり）
    /// 1) アクセシビリティ権限の確認・リクエスト
    /// 2) 監視したいイベント種別（右クリック関連）をマスクで指定
    /// 3) CGEventTap（イベントタップ）を作成してコールバックに `handleEvent` を登録
    /// 4) ランループに追加してイベント監視を開始
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) アクセシビリティ権限のリクエスト（未許可ならダイアログ表示）
        requestAccessibilityPermission()

        // 2) 監視したいイベントの種類（右クリック関連）
        //    rightMouse* : 一般的な右ボタンの押下/ドラッグ/解放
        //    otherMouse* : デバイスによって右ボタンが「other」として届くことがある（Logicool など）
        //    tapDisabled*: macOS が一時的に event tap を無効化した合図（安全のため再有効化する）
        let mask =
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue)   |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)   |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        // 3) イベントタップ（グローバルフック）を作成
        //    ・tap:   どのレイヤで拾うか（ここでは Session 全体）
        //    ・place: 先頭に差し込んで早めに受け取る
        //    ・options: .defaultTap は「読む＆（必要なら）抑止できる」モード
        //    ・eventsOfInterest: どの種類のイベントを受け取るか（上の mask）
        //    ・callback: C 関数風のコールバック。refcon に self を詰めておいて取り出す
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                // refcon から元の AppDelegate を復元してメソッドを呼ぶ
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        // 4) ランループに登録して監視開始
        if let eventTap = eventTap {
            // Mach port をランループで扱える Source に包む
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            // 現在のランループに登録して監視開始
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            print("✅ Event tap installed.")
            print("✅ CGEventTap active. Mask installed.")
        } else {
            print("⚠️ Event tap の作成に失敗。アクセシビリティ権限を確認してください。")
        }
        


        // 初期レイアウト ID を保存しておく（この ID と違う = レイアウトが変わったらキャッシュ破棄）
        self.cachedLayoutID = self.currentKeyboardLayoutID()

        // レイアウト変更通知（例: メニューバーで ABC ⇄ 日本語 を切り替えた）を購読してキャッシュをクリア
        let layoutChanged = NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(
            forName: layoutChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 3) 切り替わったらキャッシュを捨て、最新のレイアウトIDで上書きする
            guard let self else { return }
            self.keyComboCache.removeAll()
            self.cachedLayoutID = self.currentKeyboardLayoutID()
            print("🔄 Keyboard layout changed → keyComboCache cleared. NewID=\(self.cachedLayoutID ?? "nil")")
        }
        
        
        // キーボードイベントのロガー
//        startKeyboardEventLogger()
    }

    
    
    
    // MARK: - Keyboard Event Logger（自己監視用）
    // 「postCommandCharacter」で送ったキーボードイベントが OS 側でどう見えているかを
    // 自分でグローバルフック（CGEventTap）してログに出すための仕組みです。
    // ポイント：
    //  - マスクは keyDown / keyUp のみを対象にして負荷を抑える
    //  - flags に .maskCommand が含まれているかをチェック
    //  - keyCode が [ / ] に相当するかをチェック
    //  - 本番ではオフにできるよう、あくまでデバッグ用途で

    private var keyboardTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?

    func startKeyboardEventLogger() {
        // 監視対象イベント種別：キーダウン／キーアップ
        let mask = (1 << CGEventType.keyDown.rawValue) |
                   (1 << CGEventType.keyUp.rawValue)

        // C コールバックから self に戻すための refcon を準備
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        keyboardTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,            // セッション全体で捕捉
            place: .headInsertEventTap,         // できるだけ早く受け取る
            options: .listenOnly,               // ← 重要：読み取り専用（アプリ動作に影響させない）
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                // ここで「実際に OS が見ているキーイベント」を検査する
                guard type == .keyDown || type == .keyUp else {
                    return Unmanaged.passUnretained(event)
                }

                // 押された仮想キーコード（US配列基準の kVK_*）を取得
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

                // 修飾キー（Command, Control, Option, Shift など）の状態を取得
                let flags = event.flags

                // 自分が確認したい、[ と ] のキーコード
                // kVK_ANSI_LeftBracket  = 0x21
                // kVK_ANSI_RightBracket = 0x1E
                let isLeftBracket  = keyCode == CGKeyCode(kVK_ANSI_LeftBracket)
                let isRightBracket = keyCode == CGKeyCode(kVK_ANSI_RightBracket)

                // Command 修飾が付いているか？
                let hasCommand = flags.contains(.maskCommand)

                // ログを分かりやすく出す
                if type == .keyDown || type == .keyUp {
                    let t = (type == .keyDown) ? "↓ keyDown" : "↑ keyUp"
                    if hasCommand && (isLeftBracket || isRightBracket) {
                        // ここに来れば「⌘+[ or ⌘+] が “実際に OS に届いた”」ことが分かる
                        let name = isLeftBracket ? "[ (LeftBracket)" : "] (RightBracket)"
                        print("✅ \(t): Command + \(name)  keyCode=\(keyCode)")
                    } else if hasCommand {
                        print("ℹ️ \(t): Command + keyCode=\(keyCode)")
                    } else {
                        // デバッグ用（賑やかなら適宜コメントアウト）
                        // print("… \(t): keyCode=\(keyCode) flags=\(flags)")
                    }
                }

                // listenOnly なのでイベントは必ず通す
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        if let tap = keyboardTap {
            keyboardRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keyboardRunLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("🔎 Keyboard logger installed (listenOnly).")
        } else {
            print("⚠️ Keyboard logger install failed. AX権限や権限設定を確認してください。")
        }
    }
    
    
    
    func applicationWillTerminate(_ notification: Notification) {
        // 終了時の後片付け（念のため）
        if let eventTap = eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
    }

    /// アクセシビリティ権限がない場合、システムに「許可してね」と促す
    /// - ポイント：この権限がないと、イベントの監視・疑似キーボード送信ができません
    /// - 初回起動で false が返った場合は、システム設定で明示的に本アプリを ON にしてから
    ///   アプリを再度起動（再実行）してください。
    private func requestAccessibilityPermission() {
        // OK  ← Unmanaged<CFString> を String にちゃんと取り出す
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("AX trusted: \(trusted)")
        // false の場合は、システム設定で手動で本アプリを許可 → 再起動（再実行）
    }

    private func isFinderFrontmost() -> Bool {
        return frontmostBundleID() == "com.apple.finder"
    }

    // MARK: - Gesture state (ジェスチャー判定のための状態)
    // isRightClicking : 右ボタンを押している最中か？（右ドラッグ中かどうかの判定に使う）
    // startPoint      : 右ボタンを押した瞬間の座標（ここからの“相対移動量”で方向を求める）
    // lastTriggerTime : 連続誤爆を避けるためのクールダウン管理（今回は UP判定なので実質控えめ）
    // suppressNextRightMouseUp / shouldFireOnMouseUp / didDragBeyondThreshold は
    //   「右クリックメニューをどう扱うか」を調整するためのフラグです。
    private var isRightClicking = false
    private var startPoint: CGPoint?
    private var lastTriggerTime = Date.distantPast
    private var suppressNextRightMouseUp = false
    private var shouldFireOnMouseUp = false
    private var didDragBeyondThreshold = false
    private let dragSuppressThreshold: CGFloat = 8.0  // 何px動いたら「クリック」ではなく「ドラッグ」とみなすか

    // Overlay rendering (軌跡描画)
    // --- 軌跡描画（ユーザーに“いまジェスチャー中だよ”と見せるための薄いオーバーレイ） ---
    // overlayWindow : 透明・最前面・クリック透過のウインドウ（アプリの操作を邪魔しない）
    // overlayView   : 中に 1 枚だけ入っている描画用ビュー（CAShapeLayer で線を描くだけ）
    // currentOverlayFrame: どのディスプレイ上にウインドウを出しているか（そのフレーム）
    private var overlayWindow: NSWindow?
    private var overlayView: StrokeOverlayView?
    private var currentOverlayFrame: NSRect = .zero

    
    
    // MARK: - Key combo cache（文字→物理キー＋必要修飾のキャッシュ）

    /// 逆引き結果を扱いやすくするための小さな型
    private struct KeyCombo {
        let code: CGKeyCode        // 物理キー（keyCode）
        let needsShift: Bool       // Shift が必要か
        let needsOption: Bool      // Option が必要か
    }

    /// 文字（例: "[" や "w"）→ 逆引き結果 のキャッシュ
    private var keyComboCache: [Character: KeyCombo] = [:]

    /// どのレイアウトでキャッシュしたか（レイアウトが変わったら破棄するため）
    private var cachedLayoutID: String?
    
    
    /// 現在の「キーボードレイアウト」の入力ソース ID を取得する（例: "com.apple.keylayout.ABC"）
    /// - できるだけ素朴に、安全にブリッジしています
    private func currentKeyboardLayoutID() -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else {
            return nil
        }
        // あなたの環境では raw が生ポインタになるため、Unmanaged に包んでから取り出します
        let cfStr = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cfStr as String
    }
    
    
    // - Event tap callback (低レベルイベントの受け取り・判定・実行)
    /**
     イベント処理の流れ（ざっくり）：
     1) 右ボタン押下（rightMouseDown / otherMouseDown）
        - 開始座標を記録し、同時にオーバーレイ（透明な最前面ウインドウ）に軌跡描画を開始。
     2) 右ドラッグ中（rightMouseDragged / otherMouseDragged）
        - 現在座標をパスに追加して線を伸ばす。
        - 一定距離を超えたら「クリックではなくドラッグ」とみなす（右クリックメニューをESCで閉じる対応あり）。
     3) 右ボタン解放（rightMouseUp / otherMouseUp）
        - 押下開始位置からの相対移動（dx, dy）で方向を判定。
        - 左←/右→/上↑/左上↖ などに応じてショートカット（⌘+[ / ⌘+] / Mission Control / ⌘+W など）を送信。
        - 描画を片付けてオーバーレイを非表示にする。
     4) tapDisabledByTimeout など
        - OSが一時的にイベントタップを無効化したときは即座に再有効化して安定運用。
    */
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // --- macOSが tap を一時停止した通知。すぐ再開して安定運用する ---
            // Event tap が無効化された場合は即座に再有効化して復帰
            if let t = eventTap {
                CGEvent.tapEnable(tap: t, enable: true)
                print("⚠️ Event tap re-enabled after being disabled (\(type)).")
            }
            return Unmanaged.passUnretained(event)

        case .rightMouseDown:
            // --- 右ボタン押下：基準点を記録して、オーバーレイ（軌跡）を開始する ---
            // 右クリック押下開始：基準点を記録（描画のみ開始）
            isRightClicking = true
            startPoint = event.location
            beginOverlay(at: event.location)
            lastTriggerTime = .distantPast
            suppressNextRightMouseUp = false
            shouldFireOnMouseUp = true // ← 発火はUPで判定する
            didDragBeyondThreshold = false

        case .otherMouseDown:
            // --- デバイスによっては右が other 扱い。ロジックは同じ ---
            // 右クリック同等として扱う（デバイスによっては other 扱いになる）
            isRightClicking = true
            startPoint = event.location
            beginOverlay(at: event.location)
            lastTriggerTime = .distantPast
            suppressNextRightMouseUp = false
            shouldFireOnMouseUp = true
            didDragBeyondThreshold = false

        case .rightMouseUp:
            // --- 右ボタン解放：ここで dx, dy からジェスチャーを最終判定する ---
            // 右クリック終了：ここでのみ判定・実行
            isRightClicking = false
            defer {
                // 終了時に必ず軌跡を消す
                dismissOverlay()
                startPoint = nil
                shouldFireOnMouseUp = false
            }

            // 通常の右クリック（ドラッグなし）は素通し：メニューを出す
            guard shouldFireOnMouseUp, let start = startPoint else {
                return Unmanaged.passUnretained(event)
            }
            if didDragBeyondThreshold == false {
                // クリック扱い：右クリックメニューはそのまま表示
                return Unmanaged.passUnretained(event)
            }

            // ここからは「ドラッグあり」＝メニューは抑止（ただし MouseUp は OS に渡す）
            let end = event.location
            let dx = end.x - start.x
            let dy = end.y - start.y

            // --- 1) 左 ← で「戻る」 ---
            if dx < -50 && abs(dy) < 50 {
                print("← 戻る（⌘+[）")
                postCommandCharacter("[")
            }
            // --- 1.5) 右 → で「進む」 ---
            else if dx > 50 && abs(dy) < 50 {
                print("→ 進む（⌘+]）")
                postCommandCharacter("]")
            }
            // --- 1.7) 真上 ↑ で「ウィンドウ一覧（Mission Control）」 ---
            else if abs(dx) < 30 && dy < -50 {
                print("↑ ウィンドウ一覧（Mission Control 起動")
                openMissionControl()
            }
            // --- 2) 左上 ↖ で「タブを閉じる」 ---
            else if dx < -30 && dy < -25 {
                print("↖ タブを閉じる（⌘+W）")
                postCommandCharacter("w")
            }

            else if dx > 30 && dy < -25 {
                print("↗︎ タブを追加（⌘+T）")
                postCommandCharacter("t")
            }
            
            // ドラッグ中に右クリックメニューは ESC で閉じ済み。MouseUp は OS に渡す（次の右クリックが効かなくなるのを防ぐ）
            // suppressNextRightMouseUp はリセットだけに利用（将来削除予定）
            suppressNextRightMouseUp = false // ← もう使っていない（リセットのみ）
            return Unmanaged.passUnretained(event)

        case .otherMouseUp:
            // --- other の解放：右と同じロジック ---
            isRightClicking = false
            defer {
                dismissOverlay()
                startPoint = nil
                shouldFireOnMouseUp = false
            }
            guard shouldFireOnMouseUp, let start = startPoint else {
                return Unmanaged.passUnretained(event)
            }
            if didDragBeyondThreshold == false {
                return Unmanaged.passUnretained(event)
            }
            let end = event.location
            let dx = end.x - start.x
            let dy = end.y - start.y
            // --- 1) 左 ← で「戻る」 ---
            if dx < -50 && abs(dy) < 50 {
                print("← 戻る（⌘+[）")
//                postCommandKey(key: CGKeyCode(kVK_ANSI_LeftBracket))// = ⌘ + [  （キーボードの「左矢印」キー(kVK_LeftArrow)も試したが）ブラケット([)でうまくいった
                postCommandCharacter("[")
            }
            // --- 1.5) 右 → で「進む」 ---
            else if dx > 50 && abs(dy) < 50 {
                print("→ 進む（⌘+]）")
//                postCommandKey(key: CGKeyCode(kVK_ANSI_RightBracket))// = ⌘ + ]  （キーボードの「右矢印」キー(kVK_RightArrow)）
                postCommandCharacter("]")
            }
            // --- 1.7) 真上 ↑ で「ウィンドウ一覧（Mission Control）」 ---
            else if abs(dx) < 30 && dy < -50 {
                print("↑ ウィンドウ一覧（Mission Control 起動")
                openMissionControl()
            }
            // --- 2) 左上 ↖ で「タブを閉じる」 ---
            else if dx < -30 && dy < -25 {
                print("↖ タブを閉じる（⌘+W）")
                postCommandCharacter("w")
            }

            else if dx > 30 && dy < -25 {
                print("↗︎ タブを追加（⌘+T）")
                postCommandCharacter("t")
            }
            // MouseUp は OS に渡す（次の右クリックが効かなくなるのを防ぐ）
            suppressNextRightMouseUp = false // ← もう使っていない（リセットのみ）
            return Unmanaged.passUnretained(event)

        case .rightMouseDragged:
            // --- 右ドラッグ中：線を描くだけ。判定は UP でまとめて行う ---
            // 右クリック押下中に動いている（ジェスチャー中）: 描画のみ行う
            if isRightClicking {
                let now = event.location
                if let start = startPoint {
                    let dx = now.x - start.x
                    let dy = now.y - start.y
                    if !didDragBeyondThreshold && (dx*dx + dy*dy) >= (dragSuppressThreshold * dragSuppressThreshold) {
                        didDragBeyondThreshold = true
                        // 右クリックメニューを開いてしまっているアプリ向けに、しきい値到達時に ESC を一度送って閉じる
                        postKey(CGKeyCode(kVK_Escape))
                    }
                }
                addOverlayPoint(now)
                // デバッグ（必要に応じて）：
                // if let start = startPoint {
                //     let dx = now.x - start.x
                //     let dy = now.y - start.y
                //     print(String(format: "drag dx=%.1f dy=%.1f", dx, dy))
                // }
                }

        case .otherMouseDragged:
            // --- other のドラッグ中：同上（線だけ描く） ---
            if isRightClicking {
                let now = event.location
                if let start = startPoint {
                    let dx = now.x - start.x
                    let dy = now.y - start.y
                    if !didDragBeyondThreshold && (dx*dx + dy*dy) >= (dragSuppressThreshold * dragSuppressThreshold) {
                        didDragBeyondThreshold = true
                        // 右クリックメニューを開いてしまっているアプリ向けに、しきい値到達時に ESC を一度送って閉じる
                        postKey(CGKeyCode(kVK_Escape))
                    }
                }
                addOverlayPoint(now)
            }

        default:
            break
        }

        // 通常はイベントをそのまま次へ流す（抑止したいときは上で nil を返す）
        return Unmanaged.passUnretained(event)
    }

    
    /// いま有効なキーボードレイアウト（US/JISなど）の
    /// 表示名と入力ソースIDを “だけ” ログに出す超シンプル版。
    private func logCurrentKeyboardLayout(prefix: String = "Layout") {
        // 1) 現在のレイアウト（US/JISなど）を取得
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            print("⚠️ \(prefix): 入力ソースを取得できませんでした")
            return
        }

        // 2) CFStringプロパティを安全にStringへ変換する小ヘルパ
        func getString(_ key: CFString) -> String? {
            // TISGetInputSourceProperty は環境によって「生ポインタ(UnsafeMutableRawPointer?)」を返すことがある
            guard let raw = TISGetInputSourceProperty(src, key) else { return nil }
            // ← ここが肝：生ポインタ raw を Unmanaged<CFString> に包み直してから取り出す
            let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
            return cf as String
        }

        let name  = getString(kTISPropertyLocalizedName) ?? "(unknown)"
        let ident = getString(kTISPropertyInputSourceID) ?? "(unknown)"
        print("🔤 \(prefix): \(name) [\(ident)]")
    }
    
    // ------------------------------------------------------------
    // 現在のキーボードレイアウト（US/JISなど）で、
    // 指定した“文字”を出すための keyCode と必要修飾(Shift/Option)を逆引きする。
    // これにより、「配列が違っても “[`]` を生成できる物理キー＋必要修飾」を発見できる。
    // ------------------------------------------------------------
    private func keyComboForCharacter(_ ch: Character)
    -> (code: CGKeyCode, needsShift: Bool, needsOption: Bool)? {

        // ---- A) レイアウトのズレを検知してキャッシュを無効化（保険） ----
        //     通知で取りこぼした場合でも、ここで最新IDと比較してズレていればクリアします
        let currentID = currentKeyboardLayoutID()
        if currentID != cachedLayoutID {
            keyComboCache.removeAll()
            cachedLayoutID = currentID
            print("🧹 Layout ID changed during lookup → cache cleared. NewID=\(currentID ?? "nil")")
        }

        // ---- B) キャッシュがあれば即返す（総当たりを避けて高速化）----
        if let hit = keyComboCache[ch] {
//            print("キャッシュを使用")
            return (hit.code, hit.needsShift, hit.needsOption)
        }

        // ★（任意）デバッグ：いまのレイアウトを一度だけ表示
//         logCurrentKeyboardLayout(prefix: "KeyCombo lookup for '\(ch)'")

        // ---- C) ここからは “従来どおりの総当たり”（初回だけ実行される）----
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else {
            return nil // レイアウト取得失敗
        }
        let layoutData = unsafeBitCast(raw, to: CFData.self)
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(layoutPtr))

        let tries: [(UInt32, Bool, Bool)] = [
            (0, false, false),
            (UInt32(shiftKey), true, false),
            (UInt32(optionKey), false, true),
            (UInt32(shiftKey | optionKey), true, true)
        ]

        for keyCode in 0..<128 {
            for (mods, needShift, needOption) in tries {
                var deadKeyState: UInt32 = 0
                let maxLen = 8
                var buffer = Array<UniChar>(repeating: 0, count: maxLen)
                var len: Int = 0

                let err = UCKeyTranslate(
                    layout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDown),
                    (mods >> 8) & 0xFF,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    maxLen,
                    &len,
                    &buffer
                )
                if err == noErr, len > 0 {
                    let produced = String(utf16CodeUnits: buffer, count: len)
                    if produced == String(ch) {
                        // ✅ 見つかったのでキャッシュに保存（次回から即返せる）
                        let combo = KeyCombo(code: CGKeyCode(keyCode), needsShift: needShift, needsOption: needOption)
                        keyComboCache[ch] = combo
                        return (combo.code, combo.needsShift, combo.needsOption)
                    }
                }
            }
        }
        return nil
    }

    
    
    // ------------------------------------------------------------
    // 任意の“物理キーコード”をそのまま送る共通ヘルパ
    // 例：postKey(CGKeyCode(kVK_Escape)) で Esc を押して離す
    // ・修飾キーが必要なら flags に [.maskCommand] 等を渡せます
    // ------------------------------------------------------------
    func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)

        // keyDown（押す）
        if let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
            down.flags = flags          // ← 既定は修飾なし。必要なら引数で渡す
            down.post(tap: .cghidEventTap)
        }

        // keyUp（離す）
        if let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    
    // ------------------------------------------------------------
    // 「⌘ + 文字」を“レイアウトに合わせて安全に”送信する。
    // 例：postCommandCharacter("[") で、JIS/US どちらでも ⌘+[ を生成できる。
    // ・見つかったら：Command に加え、必要に応じて Shift/Option も付けて送信
    // ・見つからない：最後にフォールバック（⌘+←/→ など）を検討
    // ------------------------------------------------------------
    func postCommandCharacter(_ char: Character) {
        guard let combo = keyComboForCharacter(char) else {
            print("⚠️ '\(char)' を生成できるキーが現在のレイアウトで見つかりませんでした。")
            return
        }

        // 送信する修飾キーを組み立て。Command は必須、必要なら Shift/Option を追加
        var flags: CGEventFlags = [.maskCommand]
        if combo.needsShift  { flags.insert(.maskShift) }
        if combo.needsOption { flags.insert(.maskAlternate) }

        let src = CGEventSource(stateID: .hidSystemState)

        // keyDown（押す）
        if let down = CGEvent(keyboardEventSource: src, virtualKey: combo.code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        // keyUp（離す）
        if let up = CGEvent(keyboardEventSource: src, virtualKey: combo.code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    // ============================================================
    // レイアウト対応版：⌃ + 任意の「文字」を送る（Ctrl+char）
    // - 例：postControlCharacter("[") → US でも JIS でも ⌃+[ を正しく生成
    // - 中で keyComboForCharacter を使い、今のレイアウトでその文字を出せる
    //   物理 keyCode と、必要な Shift / Option を逆引きしてから送信します。
    // - 既存の postControlKey(key:)（キーコード直指定版）は、矢印やFキーなど
    //   レイアウト非依存キーにそのまま使えます（例：⌃+↑ など）。
    // ============================================================
    func postControlCharacter(_ char: Character) {
        // 1) 今のレイアウトで 'char' を出せる keyCode と必要修飾(Shift/Option)を逆引き
        guard let combo = keyComboForCharacter(char) else {
            print("⚠️ '\(char)' を生成できるキーが現在のレイアウトで見つかりませんでした。")
            return
        }

        // 2) 送る修飾キーを組み立て
        //    - ⌃ は必須
        //    - レイアウトにより必要な Shift / Option を自動的に追加
        var flags: CGEventFlags = [.maskControl]
        if combo.needsShift  { flags.insert(.maskShift) }
        if combo.needsOption { flags.insert(.maskAlternate) }

        // 3) 実際に「押す→離す」を送信
        let src = CGEventSource(stateID: .hidSystemState)

        // keyDown（押す）
        if let down = CGEvent(keyboardEventSource: src, virtualKey: combo.code, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        // keyUp（離す）
        if let up = CGEvent(keyboardEventSource: src, virtualKey: combo.code, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
    

    /// Command + 任意のキーを送る(レイアウトによって送信できないことがわかったので現在使用していない)
    func postCommandKey(key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState) // 信頼性を高めるため明示的なソースを使用
        
        // Commandフラグ付きのダウンイベント
        let downEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        downEvent?.flags = [.maskCommand] // 既存のフラグと結合
        downEvent?.post(tap: .cghidEventTap)
        
        // Commandフラグ付きのアップイベント
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        upEvent?.flags = [.maskCommand] // 既存のフラグと結合
        upEvent?.post(tap: .cghidEventTap)
    }
    
    /// Control + 任意キーを送る（例: ⌃+↑ で Mission Control）(レイアウトによって送信できないことがわかったので現在使用していない)
    func postControlKey(key: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        // Controlフラグ付きのダウンイベント
        let downEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        downEvent?.flags = [.maskControl]
        downEvent?.post(tap: .cghidEventTap)
        // Controlフラグ付きのアップイベント
        let upEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        upEvent?.flags = [.maskControl]
        upEvent?.post(tap: .cghidEventTap)
    }

    
    /// 右ドラッグの“軌跡”を描くだけのビュー。
    /// NSView の上に CAShapeLayer を 1 枚載せて、そこへパス（CGPath）を流し込みます。
    /// * 透明・最前面・クリック透過のウインドウの中に置かれるため、アプリの操作は邪魔しません。
    private final class StrokeOverlayView: NSView {
        private let shape = CAShapeLayer()
        private var cgPath = CGMutablePath()
        private let lineWidth: CGFloat = 3.0

        // Cocoa デフォルト: 左下原点・y↑
        override var isFlipped: Bool { false }
        override var isOpaque: Bool { false }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            // layer はデフォルトのまま（isGeometryFlipped 設定しない）

            shape.strokeColor = NSColor.orange.withAlphaComponent(0.8).cgColor
            shape.fillColor = nil
            shape.lineWidth = 5.0
            shape.lineJoin = .round
            shape.lineCap = .round

            // Disable implicit animations for geometry changes to prevent subtle shifts
            shape.actions = [
                "path": NSNull(),
                "position": NSNull(),
                "bounds": NSNull(),
                "transform": NSNull(),
                "onOrderIn": NSNull(),
                "onOrderOut": NSNull(),
                "opacity": NSNull(),
                "sublayerTransform": NSNull(),
                "anchorPoint": NSNull()
            ]
            layer?.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "transform": NSNull(),
                "onOrderIn": NSNull(),
                "onOrderOut": NSNull(),
                "opacity": NSNull(),
                "sublayerTransform": NSNull(),
                "anchorPoint": NSNull(),
                "contentsRect": NSNull()
            ]

            layer?.addSublayer(shape)
            canDrawConcurrently = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func start(at p: CGPoint) {
            cgPath = CGMutablePath()
            cgPath.move(to: p)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = cgPath
            CATransaction.commit()
        }

        func add(point p: CGPoint) {
            if cgPath.isEmpty {
                cgPath.move(to: p)
            } else {
                cgPath.addLine(to: p)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = cgPath
            CATransaction.commit()
        }

        func clear() {
            cgPath = CGMutablePath()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = cgPath
            CATransaction.commit()
        }

        override func draw(_ dirtyRect: NSRect) {
            // Drawing handled by CAShapeLayer `shape`
            // If you need a debug border, uncomment:
            // NSColor.orange.withAlphaComponent(0.08).setStroke()
            // NSBezierPath(rect: bounds).stroke()
        }
    }

    /// 指定フレーム用のオーバーレイウインドウを用意（既存と同じなら再利用）
    func ensureOverlayWindow(for frame: NSRect) {
        // 再利用：同じフレームなら再作成しない
        if let win = overlayWindow, win.frame.equalTo(frame) {
            currentOverlayFrame = frame
            return
        }
        // 既存を閉じる
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.alphaValue = 1.0
        win.backgroundColor = .clear
        win.hasShadow = false
        win.level = .screenSaver              // 最前面固定（キーにはしない）
        win.ignoresMouseEvents = true         // クリック透過
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Disable window animations
        win.animationBehavior = .none
        win.animations = [:]

        // contentView は (0,0,w,h) で作る（ウインドウ座標）
        let view = StrokeOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = view

        overlayWindow = win
        overlayView = view
        currentOverlayFrame = frame
    }

    /// Cocoa グローバル座標での現在マウス座標（NSEvent は常に Cocoa 空間）
    private func currentMouseGlobal() -> CGPoint {
        return NSEvent.mouseLocation
    }

    /// 与えた Cocoa グローバル座標に含まれる NSScreen を返す
    private func screen(containing point: CGPoint) -> NSScreen? {
        for s in NSScreen.screens { if s.frame.contains(point) { return s } }
        return NSScreen.main
    }

    /// Cocoa（左下原点・y↑）のグローバル座標 → このディスプレイのローカル座標へ
    func convertToOverlay(_ p: CGPoint) -> CGPoint {
        // グローバル画面座標 → このディスプレイのウインドウ座標へ
        // Cocoa 座標系: y↑, originは左下
        let localX = p.x - currentOverlayFrame.origin.x
        let localY = p.y - currentOverlayFrame.origin.y
        return CGPoint(x: localX, y: localY)
    }

    /// ドラッグを開始したディスプレイ上にだけ薄いオーバーレイを作る（クリック透過・最前面）
    func beginOverlay(at screenPoint: CGPoint) {
        // Quartz の event.location ではなく、NSEvent.mouseLocation (Cocoa) を使う
        let mouse = currentMouseGlobal()
        let screen = screen(containing: mouse)
        let frame = screen?.frame ?? NSScreen.screens.first?.frame ?? .zero

        ensureOverlayWindow(for: frame)
        guard let win = overlayWindow, let view = overlayView else { return }

        if !win.isVisible { win.orderFrontRegardless() }
//        win.orderFront(nil)  // Removed per instructions

        let local = convertToOverlay(mouse)
//        let inside = view.bounds.contains(local)
//        print("beginOverlay mouse=\(mouse) local=\(local) inside=\(inside) frame=\(frame)")
        view.start(at: local)
    }

    /// ドラッグ中に最新のマウス位置をローカル座標へ変換してパスを伸ばす
    func addOverlayPoint(_ screenPoint: CGPoint) {
        guard let view = overlayView else { return }
        let mouse = currentMouseGlobal()
        let local = convertToOverlay(mouse)
        view.add(point: local)
//        overlayWindow?.orderFrontRegardless() // Removed per instructions
//        overlayWindow?.orderFront(nil)        // Removed per instructions
    }

    /// 終了時に線を消してウインドウを隠す（必要なときだけ出す軽量設計）
    func dismissOverlay() {
        overlayView?.clear()
        overlayWindow?.orderOut(nil)
    }

    // MARK: - Utilities

    /// 最前面アプリの Bundle ID を取得（アプリ別の挙動切り替えに使える）
    private func frontmostBundleID() -> String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// AppleScript を単純実行（Chrome のタブ操作フォールバックなどに利用）
    private func runAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
            if let err { print("AppleScript error: \(err)") }
        }
    }

    /// 最前面アプリが Chrome なら「進む」
    private func fallbackForChromeGoForward() {
        guard frontmostBundleID() == "com.google.Chrome" else { return }
        runAppleScript(#"""
        tell application "Google Chrome"
            if (count of windows) > 0 then tell active tab of front window to go forward
        end tell
        """#)
    }

    /// 戻り値：URL解決や起動リクエストを"出せた"ら true（実際の起動成否は非同期ハンドラで判定）
    /// Mission Control を直接起動（ショートカット設定に依存しない）
    @discardableResult
    private func openMissionControl() -> Bool {
        // 1) バンドルIDからアプリURLを取得して起動（非推奨APIの置き換え）
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { print("Mission Control launch error: \(error)") }
            }
            return true // リクエストは発行できた
        }

        // 2) パスで起動を試す（存在確認のうえ起動）
        let path = "/System/Applications/Mission Control.app"
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                if let error { print("Mission Control launch error (path): \(error)") }
            }
            return true
        }
        return false
    }
}

