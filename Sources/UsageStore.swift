import SwiftUI
import ServiceManagement

@MainActor
final class UsageStore: ObservableObject {
    @Published var subscription: SubscriptionUsage?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    @Published var authMode: AuthMode {
        didSet {
            UserDefaults.standard.set(authMode.rawValue, forKey: "authMode")
            api.reset()
            resetBackoff()
            Task { await refresh(force: true) }
        }
    }
    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval") }
    }

    /// 用量階段門檻（百分比）：同時決定能量波變色與通知時機
    @Published var stageMid: Int {
        didSet { UserDefaults.standard.set(stageMid, forKey: "stageMid") }
    }
    @Published var stageHigh: Int {
        didSet { UserDefaults.standard.set(stageHigh, forKey: "stageHigh") }
    }
    @Published var notifyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notifyEnabled, forKey: "notifyEnabled")
            if notifyEnabled {
                Task {
                    await Notifier.shared.requestPermission()
                    await checkNotificationPermission()
                    if let usage = subscription { notifyCrossings(usage) }
                }
            }
        }
    }

    @Published var isOffline = false
    @Published var claudeCodeDetected = false
    @Published var notifyPermissionDenied = false
    /// claude.ai 登入在 24 小時內到期時，記下到期時間
    @Published var sessionExpiresSoon: Date?

    var stages: Stages { Stages(mid: Double(stageMid) / 100, high: Double(stageHigh) / 100) }

    private let api = UsageAPI()
    private var loop: Task<Void, Never>?
    private let tracker = ThresholdTracker()
    private var expiryNotified = false
    private let wakeWatcher = WakeWatcher()
    private let networkWatcher = NetworkWatcher()

    init() {
        let d = UserDefaults.standard
        authMode = AuthMode(rawValue: d.string(forKey: "authMode") ?? "") ?? .web
        let iv = d.double(forKey: "interval")
        interval = iv >= 30 ? iv : 120
        let mid = d.integer(forKey: "stageMid")
        let high = d.integer(forKey: "stageHigh")
        let valid = mid >= 10 && high <= 95 && mid + 5 <= high
        stageMid = valid ? mid : 50
        stageHigh = valid ? high : 80
        notifyEnabled = d.object(forKey: "notifyEnabled") as? Bool ?? true
        ClaudeWeb.shared.onLoginClosed = { [weak self] in
            guard let self else { return }
            self.resetBackoff()
            Task { await self.checkLogin(); await self.refresh(force: true) }
        }

        Notifier.shared.activate()
        if notifyEnabled { Task { await Notifier.shared.requestPermission() } }
        wakeWatcher.start { [weak self] in await self?.refresh(force: true) }
        networkWatcher.start { [weak self] online in
            guard let self else { return }
            self.isOffline = !online
            if online { Task { await self.refresh(force: true) } }
        }

        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let secs = self?.interval ?? 60
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
        }
    }

    private var lastAttempt: Date?
    private var blockedUntil: Date?
    private var backoff: TimeInterval = 0

    /// force = 使用者按重新整理；否則 25 秒內不重複請求
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        if isOffline {
            errorMessage = nil
            return
        }
        let now = Date()
        if let until = blockedUntil, until > now {
            let mins = max(1, Int(until.timeIntervalSince(now) / 60 + 0.5))
            errorMessage = "請求太頻繁，伺服器暫時限流。約 \(mins) 分鐘後自動重試。"
            return
        }
        if !force, let last = lastAttempt, now.timeIntervalSince(last) < 25 { return }

        isRefreshing = true
        lastAttempt = now
        defer { isRefreshing = false }

        do {
            let usage = try await api.fetch(mode: authMode)
            subscription = usage
            errorMessage = nil
            backoff = 0
            blockedUntil = nil
            lastUpdated = Date()
            notifyCrossings(usage)
            await updateExpiry()
        } catch let r as RateLimited {
            backoff = backoff == 0 ? 120 : min(backoff * 2, 900)
            let wait = max(r.retryAfter ?? 0, backoff)
            blockedUntil = Date().addingTimeInterval(wait)
            let mins = max(1, Int(wait / 60 + 0.5))
            errorMessage = "請求太頻繁，伺服器暫時限流。約 \(mins) 分鐘後自動重試。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 調整門檻時保持 10 ≤ mid、mid + 5 ≤ high ≤ 95
    func setStageMid(_ value: Int) { stageMid = min(max(value, 10), stageHigh - 5) }
    func setStageHigh(_ value: Int) { stageHigh = min(max(value, stageMid + 5), 95) }

    private func notifyCrossings(_ usage: SubscriptionUsage) {
        guard notifyEnabled else { return }
        let marks = [stageMid, stageHigh]
        let windows: [(key: String, name: String, window: UsageWindow?)] = [
            ("fiveHour", "目前 Session", usage.fiveHour),
            ("sevenDay", "每週額度", usage.sevenDay),
        ]
        for item in windows {
            guard let window = item.window, let value = window.utilization else { continue }
            // 以「重置時間（取到小時）」當作週期，避免伺服器時間的小幅變動被當成新週期
            let period = window.resetDate.map { String(Int($0.timeIntervalSince1970 / 3600)) } ?? "none"
            let hits = tracker.due(key: item.key, period: period, value: value, thresholds: marks)
            guard let top = hits.max() else { continue }
            Notifier.shared.send(
                id: "\(item.key)-\(top)-\(period)",
                title: "Claude 用量已達 \(top)%",
                body: "\(item.name)目前 \(Int(value.rounded()))%，\(Fmt.countdown(to: window.resetDate))。"
            )
        }
    }

    func checkClaudeCode() async {
        claudeCodeDetected = await Task.detached { UsageAPI.claudeCodeLoginExists() }.value
    }

    func checkNotificationPermission() async {
        notifyPermissionDenied = await Notifier.shared.isDenied()
    }

    func sendTestNotification() async {
        await Notifier.shared.requestPermission()
        await checkNotificationPermission()
        guard !notifyPermissionDenied else { return }
        Notifier.shared.send(id: "test-\(Date().timeIntervalSince1970)",
                             title: "KiMeter 測試通知",
                             body: "通知正常！用量到達 \(stageMid)% 和 \(stageHigh)% 時會這樣提醒你。")
    }

    private func updateExpiry() async {
        guard let expiry = await ClaudeWeb.shared.sessionExpiry() else {
            sessionExpiresSoon = nil
            return
        }
        let left = expiry.timeIntervalSinceNow
        sessionExpiresSoon = (left > 0 && left < 86_400) ? expiry : nil
        guard sessionExpiresSoon != nil else {
            expiryNotified = false
            return
        }
        if notifyEnabled && !expiryNotified {
            expiryNotified = true
            Notifier.shared.send(id: "session-expiry",
                                 title: "claude.ai 登入快過期了",
                                 body: "KiMeter 的登入將在 24 小時內到期，請重新登入以免中斷。")
        }
    }

    func saveCookie(_ raw: String) {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("sessionKey=") { v.removeFirst("sessionKey=".count) }
        let key = v
        if !key.isEmpty && !ClaudeWeb.isValidSessionKey(key) {
            errorMessage = "sessionKey 格式不正確，請重新複製（開頭是 sk-ant-sid01-）。"
            return
        }
        api.reset()
        resetBackoff()
        Task {
            if key.isEmpty { await ClaudeWeb.shared.signOut() } else { await ClaudeWeb.shared.setSessionKey(key) }
            await checkLogin()
            await refresh(force: true)
        }
    }

    @Published var webLoggedIn = false

    func checkLogin() async { webLoggedIn = await ClaudeWeb.shared.hasSession() }

    func login() { ClaudeWeb.shared.showLogin() }

    func resetBackoff() {
        backoff = 0
        blockedUntil = nil
        lastAttempt = nil
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                errorMessage = "開機啟動設定失敗：\(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
