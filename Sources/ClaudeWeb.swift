import AppKit
import WebKit

/// 用內建的 WebKit 以 claude.ai 網頁身份讀用量。
/// 跟你在瀏覽器打開「設定 → 用量」讀的是同一份資料，不會呼叫模型、不耗 token。
@MainActor
final class ClaudeWeb: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = ClaudeWeb()

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    var onLoginClosed: (() -> Void)?

    private var ready = false
    private var loadCont: CheckedContinuation<Void, Error>?
    private var loginWindow: NSWindow?
    private var loginWeb: WKWebView?
    private var popups: [ObjectIdentifier: NSWindow] = [:]

    private lazy var worker: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        w.customUserAgent = Self.userAgent
        w.navigationDelegate = self
        return w
    }()

    // MARK: 登入狀態

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    func hasSession() async -> Bool {
        await allCookies().contains { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }
    }

    /// 這個 app 自己瀏覽器裡 claude.ai 登入的到期時間
    func sessionExpiry() async -> Date? {
        await allCookies()
            .first { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }?
            .expiresDate
    }

    /// sessionKey 只會由英數字、- 和 _ 組成；其他內容一律拒絕，避免被塞入多餘的 cookie 屬性
    static func isValidSessionKey(_ key: String) -> Bool {
        guard (20...512).contains(key.count) else { return false }
        return key.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    /// 把使用者貼上的 sessionKey 放進內建瀏覽器（只限 HTTPS、網頁腳本讀不到）
    func setSessionKey(_ key: String) async {
        guard Self.isValidSessionKey(key) else { return }
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "sessionKey", .value: key, .domain: ".claude.ai", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue,
        ]
        guard let c = HTTPCookie(properties: props) else { return }
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.setCookie(c) { cont.resume() }
        }
        ready = false
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { cont.resume(returning: $0) }
        }
        let claude = records.filter { $0.displayName.contains("claude.ai") }
        await withCheckedContinuation { cont in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: claude) { cont.resume() }
        }
        ready = false
    }

    // MARK: 讀用量

    private func ensureReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loadCont = c
            worker.load(URLRequest(url: URL(string: "https://claude.ai/robots.txt")!))
        }
        ready = true
    }

    /// 只允許登入與讀用量需要的網域，其他一律擋下
    static let allowedDomains = [
        "claude.ai", "claude.com", "anthropic.com",
        "google.com", "gstatic.com", "apple.com", "cloudflare.com",
    ]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 頁面內嵌的框框（登入按鈕、瀏覽器驗證）可以使用 https 與瀏覽器內部網址，但不能是本機檔案或其他協定
    static func isAllowedInFrame(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["https", "about", "blob", "data"].contains(scheme)
    }

    /// 整個視窗只能停在白名單網站；頁面裡嵌入的框框則放寬，讓登入與驗證能正常運作
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let allowed = isMainFrame ? Self.isAllowed(url) : Self.isAllowedInFrame(url)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === worker { finishLoad(nil) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === worker { finishLoad(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === worker { finishLoad(error) }
    }

    private func finishLoad(_ e: Error?) {
        guard let c = loadCont else { return }
        loadCont = nil
        if let e { c.resume(throwing: e) } else { c.resume() }
    }

    func fetchUsage() async throws -> SubscriptionUsage {
        try await ensureReady()
        let js = """
        const o = await fetch('/api/organizations', {credentials: 'include'});
        if (!o.ok) return JSON.stringify({status: o.status});
        const orgs = await o.json();
        const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
        if (!org) return JSON.stringify({status: 404});
        const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
        return JSON.stringify({status: u.status, body: u.ok ? await u.text() : ''});
        """
        let raw: Any?
        do {
            raw = try await worker.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            ready = false
            throw APIError("無法連到 claude.ai：\(error.localizedDescription)")
        }
        guard let s = raw as? String, let d = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let status = (obj["status"] as? NSNumber)?.intValue else {
            throw APIError("claude.ai 回應格式不正確")
        }
        if status == 401 || status == 403 {
            throw APIError("尚未登入 claude.ai。點齒輪 →「在 app 內登入 claude.ai」。")
        }
        if status == 429 { throw RateLimited(retryAfter: nil) }
        guard status == 200, let body = (obj["body"] as? String)?.data(using: .utf8) else {
            throw APIError("claude.ai 回應 \(status)")
        }
        return try JSONDecoder().decode(SubscriptionUsage.self, from: body)
    }

    // MARK: 登入視窗

    func showLogin() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = loginWindow { w.makeKeyAndOrderFront(nil); return }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = Self.userAgent
        web.uiDelegate = self
        web.navigationDelegate = self
        web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "登入 claude.ai（登入後會自動關閉）"
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        loginWindow = w
        loginWeb = web
        w.makeKeyAndOrderFront(nil)

        Task { [weak self] in
            while let self, self.loginWindow != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let path = self.loginWeb?.url?.path ?? "/login"
                if !path.contains("login"), !path.contains("magic-link"), await self.hasSession() {
                    self.loginWindow?.close()
                    break
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        loginWindow = nil
        loginWeb = nil
        ready = false
        onLoginClosed?()
    }
}

// MARK: - Google / Apple 登入需要的彈出視窗

extension ClaudeWeb: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        guard url == nil || url?.absoluteString.isEmpty == true || Self.isAllowed(url) else { return nil }
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = Self.userAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "登入"
        w.contentView = popup
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups[ObjectIdentifier(popup)] = w
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeValue(forKey: ObjectIdentifier(webView))?.close()
    }
}
