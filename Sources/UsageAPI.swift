import Foundation

/// 讀取用量時使用的登入。
/// rawValue 沿用舊版的 "auto"，舊設定（含已移除的 "cookie"）都會落到 .web。
enum AuthMode: String, CaseIterable, Identifiable {
    case web = "auto"
    case claudeCode
    var id: String { rawValue }
}

/// 只讀取用量數字，不呼叫任何模型 → 不消耗 token。
@MainActor
final class UsageAPI {
    private var cachedToken: String?
    private var cachedTokenExpiry: Date?

    private let session: URLSession = {
        // 不存 cookie、不留快取：登入 token 只在記憶體裡，用完即丟
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: c)
    }()

    func reset() {
        cachedToken = nil
        cachedTokenExpiry = nil
    }

    func fetch(mode: AuthMode) async throws -> SubscriptionUsage {
        switch mode {
        case .claudeCode:
            return try await fetchViaOAuth()
        case .web:
            // 優先走 claude.ai 網頁（最穩），沒登入才用 Claude Code 的登入
            let loggedIn = await ClaudeWeb.shared.hasSession()
            if loggedIn {
                do { return try await fetchViaWeb() } catch {
                    if let r = try? await fetchViaOAuth() { return r }
                    throw error
                }
            }
            return try await fetchViaOAuth()
        }
    }

    private func fetchViaWeb() async throws -> SubscriptionUsage {
        let web = ClaudeWeb.shared
        guard await web.hasSession() else {
            throw APIError("尚未登入 claude.ai。點齒輪 →「在 app 內登入 claude.ai」。")
        }
        return try await web.fetchUsage()
    }

    /// 只檢查 Claude Code 登入是否存在，不讀取內容，也不會跳出鑰匙圈詢問
    nonisolated static func claudeCodeLoginExists() -> Bool {
        let credentials = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if FileManager.default.fileExists(atPath: credentials.path) { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated static func retryAfter(_ resp: URLResponse) -> TimeInterval? {
        guard let v = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
              let s = Double(v.trimmingCharacters(in: .whitespaces)) else { return nil }
        return s
    }

    // MARK: Claude Code 的 OAuth 登入（存在 macOS 鑰匙圈）

    nonisolated static func readOAuthToken() throws -> (token: String, expiry: Date?) {
        var raw: String?

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                raw = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            }
        } catch {}

        if raw == nil {
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            raw = try? String(contentsOf: url, encoding: .utf8)
        }

        guard let raw,
              let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else {
            throw APIError("找不到 Claude Code 登入資訊。請先在終端機執行 claude 並登入，或改用 claude.ai 登入。")
        }
        let expiry = (oauth["expiresAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000)
        }
        return (token, expiry)
    }

    private func fetchViaOAuth() async throws -> SubscriptionUsage {
        if let exp = cachedTokenExpiry, exp < Date() {
            cachedToken = nil
            cachedTokenExpiry = nil
        }
        if cachedToken == nil {
            let r = try await Task.detached { try UsageAPI.readOAuthToken() }.value
            cachedToken = r.token
            cachedTokenExpiry = r.expiry
        }
        if let exp = cachedTokenExpiry, exp < Date() {
            cachedToken = nil
            throw APIError("Claude Code 登入已過期。打開 Claude Code 用一下就會自動更新。")
        }
        guard let token = cachedToken else { throw APIError("無法取得 Claude Code 登入。") }

        for path in ["/api/oauth/usage", "/api/oauth/organizations/me/usage"] {
            var req = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpShouldHandleCookies = false
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { continue }
            if code == 429 { throw RateLimited(retryAfter: Self.retryAfter(resp)) }
            if code == 401 || code == 403 {
                cachedToken = nil
                throw APIError("Claude Code 登入已失效（\(code)）。打開 Claude Code 用一下即可更新。")
            }
            guard code == 200 else { throw APIError("用量 API 回應 \(code)") }
            return try JSONDecoder().decode(SubscriptionUsage.self, from: data)
        }
        throw APIError("找不到用量 API（可能已改版），請改用 claude.ai 登入。")
    }
}
