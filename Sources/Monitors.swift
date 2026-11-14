import AppKit
import Network
import UserNotifications

// MARK: - 系統通知

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    func send(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 選單列 app 也要能跳出橫幅
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// 記錄每條用量在「這個週期」已經通知過哪些門檻（存在本機）。
/// 用量 ≥ 門檻且本週期還沒通知過，就通知一次；重開 app 不會重複，週期重置後重新計算。
struct ThresholdTracker {
    private let defaults = UserDefaults.standard

    func due(key: String, period: String, value: Double, thresholds: [Int]) -> [Int] {
        let storeKey = "notified.\(key)"
        let saved = defaults.dictionary(forKey: storeKey) as? [String: [Int]] ?? [:]
        // 用量掉回門檻以下的，重新武裝
        var done = Set((saved[period] ?? []).filter { Double($0) <= value })
        let hits = thresholds.filter { value >= Double($0) && !done.contains($0) }
        done.formUnion(hits)
        defaults.set([period: Array(done)], forKey: storeKey)
        return hits
    }
}

// MARK: - 睡眠喚醒

@MainActor
final class WakeWatcher {
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    /// 喚醒後等網路恢復再呼叫一次 action；短時間內多次喚醒只算一次
    func start(delay seconds: Double = 5, action: @escaping @MainActor () async -> Void) {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pending?.cancel()
                self.pending = Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await action()
                }
            }
        }
    }
}

// MARK: - 網路連線

@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                onChange(online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "KiMeter.network"))
    }
}
