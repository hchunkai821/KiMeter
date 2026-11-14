import Foundation

// MARK: - 訂閱額度（claude.ai 與 Claude Code 共用）

struct UsageWindow: Decodable, Equatable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var fraction: Double { min(max((utilization ?? 0) / 100, 0), 1) }
    var resetDate: Date? { resetsAt.flatMap(DateParse.iso) }
}

struct SubscriptionUsage: Decodable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

// MARK: - 工具

struct APIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RateLimited: Error {
    let retryAfter: TimeInterval?
}

enum DateParse {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func iso(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}

enum Fmt {
    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }

    static func countdown(to date: Date?) -> String {
        guard let date else { return " " }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "即將重置" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        let tf = DateFormatter()
        tf.dateFormat = d > 0 ? "M/d HH:mm" : "HH:mm"
        let rel: String
        if d > 0 { rel = "\(d) 天 \(h) 小時" }
        else if h > 0 { rel = "\(h) 小時 \(m) 分" }
        else { rel = "\(m) 分鐘" }
        return "\(rel)後重置 · \(tf.string(from: date))"
    }
}
