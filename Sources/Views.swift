import SwiftUI
import AppKit

// MARK: - 選單列標籤

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let u = store.subscription?.fiveHour?.utilization
        HStack(spacing: 3) {
            Image(nsImage: MiniBeam.image(fraction: u.map { $0 / 100 }, stages: store.stages))
            Text(u.map { "\(Int($0.rounded()))%" } ?? (store.errorMessage != nil ? "!" : "…"))
        }
    }
}

// MARK: - 像素風外框

struct PixelBox: ViewModifier {
    var fill: Color
    var border: Color = Pixel.border
    var width: CGFloat = 2
    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: width))
    }
}

extension View {
    func pixelBox(_ fill: Color, border: Color = Pixel.border, width: CGFloat = 2) -> some View {
        modifier(PixelBox(fill: fill, border: border, width: width))
    }
}

struct PixelButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Pixel.text)
                .frame(width: 24, height: 24)
                .pixelBox(Pixel.panel)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 彈出面板

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if showSettings {
                SettingsView(done: { showSettings = false })
            } else {
                content
            }
        }
        .padding(14)
        .frame(width: 380)
        .background(Pixel.bg)
        .overlay(Rectangle().strokeBorder(Pixel.border, lineWidth: 3))
        .foregroundStyle(Pixel.text)
        .environment(\.colorScheme, .dark)
        .onAppear { Task { await store.checkLogin(); await store.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("▶ CLAUDE 用量").font(Pixel.font(14, .bold))
            Spacer()
            Text(updatedText).font(Pixel.font(10)).foregroundStyle(Pixel.sub)
            PixelButton(symbol: store.isRefreshing ? "hourglass" : "arrow.clockwise") {
                Task { await store.refresh(force: true) }
            }
            PixelButton(symbol: showSettings ? "xmark" : "gearshape") { showSettings.toggle() }
        }
    }

    private var updatedText: String {
        guard let d = store.lastUpdated else { return "載入中…" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "更新於 \(f.string(from: d))"
    }

    @ViewBuilder private var content: some View {
        let waiting = store.webLoggedIn ? "集氣中…" : "登入 claude.ai 後開始集氣"
        if let w = store.subscription?.fiveHour, w.utilization != nil {
            HeroRow(title: "目前 Session · 5 小時", window: w, stages: store.stages)
        } else {
            IdleRow(title: "目前 Session · 5 小時", note: store.subscription == nil ? waiting : "暫時沒有資料")
        }
        if let w = store.subscription?.sevenDay, w.utilization != nil {
            HeroRow(title: "每週 · 所有模型", window: w, stages: store.stages)
        } else {
            IdleRow(title: "每週 · 所有模型", note: store.subscription == nil ? waiting : "暫時沒有資料")
        }
        if store.isOffline {
            NoticeBox(symbol: "wifi.slash", text: "目前離線，連上網路後會自動更新。", tint: Pixel.sub)
        } else if let e = store.errorMessage {
            ErrorBox(text: e)
        }
        if let expiry = store.sessionExpiresSoon {
            Button { store.login() } label: {
                NoticeBox(symbol: "clock.badge.exclamationmark",
                          text: "claude.ai 登入將於 \(Fmt.shortTime(expiry)) 到期，點這裡重新登入。",
                          tint: Color(hex: 0xFFB13D))
            }
            .buttonStyle(.plain)
        }
        if !store.webLoggedIn && (store.errorMessage != nil || store.subscription == nil) {
            Button { store.login() } label: {
                Text("▶ 登入 claude.ai").font(Pixel.font(12, .bold))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .pixelBox(Color(hex: 0x2A2F6A), border: Color(hex: 0x5A6BFF))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 列

struct HeroRow: View {
    let title: String
    let window: UsageWindow
    var stages: Stages = .standard

    var body: some View {
        let p = BeamPalette.forLevel(window.fraction, stages)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Pixel.font(12, .semibold))
                Spacer()
                Text("\(Int((window.utilization ?? 0).rounded()))%")
                    .font(Pixel.font(22, .bold))
                    .foregroundStyle(stages.isMid(window.fraction) ? p.core : Pixel.text)
            }
            HeroBeamView(fraction: window.fraction, stages: stages)
            Text(Fmt.countdown(to: window.resetDate)).font(Pixel.font(10)).foregroundStyle(Pixel.sub)
        }
        .padding(10)
        .pixelBox(Pixel.panel, border: stages.isHigh(window.fraction) ? p.glow.opacity(0.7) : Pixel.border)
    }
}

struct IdleRow: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Pixel.font(12, .semibold))
                Spacer()
                Text("--%").font(Pixel.font(22, .bold)).foregroundStyle(Pixel.sub)
            }
            HeroBeamView(fraction: 0)
            Text(note).font(Pixel.font(10)).foregroundStyle(Pixel.sub)
        }
        .padding(10)
        .pixelBox(Pixel.panel)
    }
}

struct NoticeBox: View {
    let symbol: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
            Text(text).font(Pixel.font(11)).foregroundStyle(Pixel.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .pixelBox(Pixel.panel, border: tint.opacity(0.6))
    }
}

struct ErrorBox: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("!").font(Pixel.font(14, .bold)).foregroundStyle(Color(hex: 0xFFB13D))
            Text(text).font(Pixel.font(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .pixelBox(Pixel.panel, border: Color(hex: 0xFFB13D).opacity(0.6))
    }
}

// MARK: - 設定

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore
    @State private var cookie = ""
    var done: () -> Void

    private static let ok = Color(hex: 0x5FE39A)
    private static let warn = Color(hex: 0xFFB13D)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登入方式").font(Pixel.font(12, .bold))
            webCard
            claudeCodeCard

            Text("用量階段").font(Pixel.font(12, .bold)).padding(.top, 4)
            StageSlider(mid: store.stageMid, high: store.stageHigh,
                        setMid: store.setStageMid, setHigh: store.setStageHigh)
            notificationRow

            HStack {
                Text("更新頻率").font(Pixel.font(12))
                Spacer()
                Picker("", selection: $store.interval) {
                    Text("30 秒").tag(30.0)
                    Text("1 分鐘").tag(60.0)
                    Text("2 分鐘").tag(120.0)
                    Text("5 分鐘").tag(300.0)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            .padding(.top, 4)
            Toggle("登入 Mac 時自動啟動", isOn: $store.launchAtLogin).font(Pixel.font(12))

            HStack {
                Button("結束 KiMeter") { NSApp.terminate(nil) }
                Spacer()
                Button("完成") { done() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(10)
        .pixelBox(Pixel.panel)
        .task {
            await store.checkLogin()
            await store.checkClaudeCode()
            await store.checkNotificationPermission()
        }
    }

    // MARK: claude.ai

    private var webCard: some View {
        LoginCard(title: "claude.ai 登入（建議）", selected: store.authMode == .web) {
            store.authMode = .web
        } content: {
            HStack {
                status(store.webLoggedIn, on: "已登入", off: "未登入")
                Spacer()
                Button(store.webLoggedIn ? "重新登入" : "登入 claude.ai") { store.login() }
            }
            hint("在跳出的視窗登入 claude.ai，完成後會自動關閉。只讀用量，不耗 token。")

            DisclosureGroup("登入不了？改貼 sessionKey") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField(store.webLoggedIn ? "已登入（貼上新的可覆蓋）" : "sk-ant-sid01-…", text: $cookie)
                            .textFieldStyle(.roundedBorder)
                        Button("儲存") { store.saveCookie(cookie); cookie = "" }
                            .disabled(cookie.isEmpty)
                    }
                    hint("Chrome：⌥⌘I → Application → Cookies → claude.ai → 複製 sessionKey。\nSafari：先在「設定 → 進階」打開網頁開發者功能，再 ⌥⌘I → 儲存空間 → Cookie → claude.ai。")
                    if store.webLoggedIn {
                        Button("登出並清除") { store.saveCookie("") }
                            .buttonStyle(.link).font(Pixel.font(11))
                    }
                }
                .padding(.top, 4)
            }
            .font(Pixel.font(11))
        }
    }

    // MARK: Claude Code

    private var claudeCodeCard: some View {
        LoginCard(title: "Claude Code 登入", selected: store.authMode == .claudeCode) {
            store.authMode = .claudeCode
        } content: {
            HStack {
                status(store.claudeCodeDetected, on: "已偵測到登入", off: "找不到登入")
                Spacer()
                Button("重新偵測") { Task { await store.checkClaudeCode() } }
            }
            hint("1. 在終端機執行 claude\n2. 輸入 /login 完成登入\n3. 選這張卡；第一次讀取時 macOS 會詢問鑰匙圈，按「永遠允許」。")
            hint("這條較常被伺服器限流，建議以 claude.ai 登入為主。")
        }
    }

    // MARK: 通知

    private var notificationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("達到階段門檻時發送通知", isOn: $store.notifyEnabled).font(Pixel.font(12))
                Spacer()
                Button("測試") { Task { await store.sendTestNotification() } }
                    .disabled(!store.notifyEnabled)
            }
            if store.notifyPermissionDenied {
                Text("通知權限被關閉了。請到「系統設定 → 通知 → KiMeter」打開「允許通知」。")
                    .font(Pixel.font(10)).foregroundStyle(Self.warn)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                hint("拖動白色把手調整。用量到達每個門檻時能量波會變色，並在每個週期通知一次。")
            }
        }
    }

    // MARK: 小元件

    private func status(_ isOn: Bool, on: String, off: String) -> some View {
        Text(isOn ? "● \(on)" : "○ \(off)")
            .font(Pixel.font(11))
            .foregroundStyle(isOn ? Self.ok : Pixel.sub)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Pixel.font(10)).foregroundStyle(Pixel.sub)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 可點選的登入方式卡片
struct LoginCard<Content: View>: View {
    let title: String
    let selected: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: Content

    private static var accent: Color { Color(hex: 0x5A8BFF) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Self.accent : Pixel.sub)
                    Text(title).font(Pixel.font(12, .bold))
                    Spacer()
                    if selected {
                        Text("使用中").font(Pixel.font(10, .bold)).foregroundStyle(Self.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            content
        }
        .padding(10)
        .pixelBox(Color(hex: 0x12152E), border: selected ? Color(hex: 0x5A6BFF) : Pixel.border)
    }
}

// MARK: - 用量階段：三色像素條 + 兩個拖拉把手

struct StageSlider: View {
    let mid: Int
    let high: Int
    let setMid: (Int) -> Void
    let setHigh: (Int) -> Void

    private static let blue = Color(hex: 0x38A8FF)
    private static let purple = Color(hex: 0x9A86FF)
    private static let orange = Color(hex: 0xFF8A3D)
    private static let outline = Color(hex: 0x07080F)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        Rectangle().fill(Self.blue).frame(width: width * CGFloat(mid) / 100)
                        Rectangle().fill(Self.purple).frame(width: width * CGFloat(high - mid) / 100)
                        Rectangle().fill(Self.orange)
                    }
                    .frame(height: 12)
                    .overlay(Rectangle().strokeBorder(Self.outline, lineWidth: 2))
                    .offset(y: 23)
                    handle(value: mid, width: width, set: setMid)
                    handle(value: high, width: width, set: setHigh)
                }
                .coordinateSpace(name: "stageBar")
            }
            .frame(height: 44)
            .padding(.horizontal, 6)

            HStack {
                legend(Self.blue, "0–\(mid)%")
                Spacer()
                legend(Self.purple, "\(mid)–\(high)%")
                Spacer()
                legend(Self.orange, "\(high)–100%")
            }
        }
    }

    private func handle(value: Int, width: CGFloat, set: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 2) {
            Text("\(value)%").font(Pixel.font(10, .bold))
            Rectangle().fill(Color.white).frame(width: 8, height: 20)
                .overlay(Rectangle().strokeBorder(Self.outline, lineWidth: 2))
        }
        .frame(width: 40)
        .contentShape(Rectangle())
        .position(x: width * CGFloat(value) / 100, y: 22)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("stageBar"))
                .onChanged { drag in
                    guard width > 0 else { return }
                    let raw = drag.location.x / width * 100
                    set(Int((raw / 5).rounded()) * 5)
                }
        )
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(text).font(Pixel.font(10)).foregroundStyle(Pixel.sub)
        }
    }
}
