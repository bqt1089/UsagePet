#if os(macOS)
import AppKit
import WebKit
import ClaudeUsageCore

/// Presents an in-app, non-persistent `WKWebView` pointed at
/// `claude.ai/login`, watches its own cookie store (never the system or
/// browser cookie stores) for the `sessionKey` cookie to appear, verifies
/// it works (organization discovery + a first usage fetch), then saves it
/// to this app's Keychain and switches `AccountManager` to `.claudeWeb`.
///
/// Everything here runs on the main actor: the web view, the window, and
/// the `WKNavigationDelegate` / `WKHTTPCookieStoreObserver` conformances
/// below (both isolated to this `@MainActor` type; their protocol
/// callbacks are `nonisolated` and hop back with a `Task { @MainActor in }`
/// before touching any state).
@MainActor
final class ClaudeWebLoginWindow: NSObject {

    /// A fixed Safari-like UA set on the web view before it loads, and
    /// reused for every subsequent API call so claude.ai sees the same
    /// client throughout.
    static let userAgent = ClaudeWebUsageClient.defaultUserAgent

    private static var shared: ClaudeWebLoginWindow?

    private let accountManager: AccountManager
    private var window: NSWindow?
    private var webView: WKWebView!
    private var cookieObserver: CookieObserver?
    private var errorLabel: NSTextField!
    private var retryButton: NSButton!
    private var progressIndicator: NSProgressIndicator!

    private var capturedSessionKey: String?
    private var isVerifying = false

    private init(accountManager: AccountManager) {
        self.accountManager = accountManager
        super.init()
    }

    /// Shows the sign-in window, or brings the existing one forward if it's
    /// already open. Safe to call from Settings or the widget's link
    /// section.
    static func present(accountManager: AccountManager) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = ClaudeWebLoginWindow(accountManager: accountManager)
        shared = controller
        controller.buildWindow()
    }

    private func buildWindow() {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 456, height: 560), configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView

        let hintLabel = NSTextField(wrappingLabelWithString:
            "Tip: if \u{201C}Continue with Google\u{201D} is blocked here, use \u{201C}Continue with email\u{201D} \u{2014} Claude sends you a sign-in code.")
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        self.errorLabel = errorLabel

        let retryButton = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        retryButton.isHidden = true
        self.retryButton = retryButton

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true
        self.progressIndicator = progressIndicator

        let statusRow = NSStackView(views: [errorLabel, retryButton, progressIndicator])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let stack = NSStackView(views: [hintLabel, webView, statusRow])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.contentView = stack
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let observer = CookieObserver(dataStore: dataStore) { [weak self] value in
            guard let self else { return }
            self.handleCookieCaptured(value)
        }
        cookieObserver = observer

        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    private func handleCookieCaptured(_ sessionKey: String) {
        guard capturedSessionKey == nil, !isVerifying else { return }
        capturedSessionKey = sessionKey
        verify(sessionKey: sessionKey)
    }

    private func verify(sessionKey: String) {
        isVerifying = true
        errorLabel.isHidden = true
        retryButton.isHidden = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let client = ClaudeWebUsageClient(sessionKey: sessionKey, userAgent: Self.userAgent)
                let orgId = try await client.resolvedOrganizationId()
                _ = try await client.fetch(force: true)
                let accountInfo = await ClaudeWebUsageClient.fetchAccountInfo(sessionKey: sessionKey, userAgent: Self.userAgent)

                var session = ClaudeWebSession(
                    sessionKey: sessionKey,
                    orgId: orgId,
                    orgName: nil,
                    email: nil,
                    displayName: nil,
                    userAgent: Self.userAgent
                )
                session.email = accountInfo?.email
                session.displayName = accountInfo?.name
                self.accountManager.linkClaudeWebSession(session)
                self.close()
            } catch {
                self.isVerifying = false
                self.capturedSessionKey = nil
                self.progressIndicator.stopAnimation(nil)
                self.progressIndicator.isHidden = true
                self.errorLabel.stringValue = "Signed in, but couldn't read usage: \(Self.describe(error))."
                self.errorLabel.isHidden = false
                self.retryButton.isHidden = false
            }
        }
    }

    @objc private func retryTapped() {
        guard let sessionKey = capturedSessionKey else { return }
        verify(sessionKey: sessionKey)
    }

    private func handleWindowClosed() {
        cookieObserver?.stop()
        cookieObserver = nil
        Self.shared = nil
    }

    private func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        handleWindowClosed()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case UsageClientError.unauthorized:
            return "session expired"
        case UsageClientError.http(let code):
            return "server error (\(code))"
        case UsageClientError.rateLimited:
            return "rate limited, try again shortly"
        case UsageClientError.parse:
            return "unexpected response"
        default:
            return "network error"
        }
    }
}

extension ClaudeWebLoginWindow: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.checkCookiesAfterNavigation()
        }
    }

    private func checkCookiesAfterNavigation() {
        guard capturedSessionKey == nil else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            Task { @MainActor in
                if let cookie = cookies.first(where: { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }) {
                    self.handleCookieCaptured(cookie.value)
                }
            }
        }
    }
}

extension ClaudeWebLoginWindow: NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.handleWindowClosed()
        }
    }
}

/// Watches a non-persistent `WKWebsiteDataStore`'s cookie store for the
/// `sessionKey` cookie landing on a claude.ai domain, and calls `onCapture`
/// once with its value. Never reads the system/browser cookie stores —
/// only this web view's own, isolated one.
@MainActor
private final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
    private let dataStore: WKWebsiteDataStore
    private let onCapture: (String) -> Void
    private var fired = false

    init(dataStore: WKWebsiteDataStore, onCapture: @escaping (String) -> Void) {
        self.dataStore = dataStore
        self.onCapture = onCapture
        super.init()
        dataStore.httpCookieStore.add(self)
    }

    func stop() {
        dataStore.httpCookieStore.remove(self)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            Task { @MainActor in
                guard !self.fired else { return }
                if let cookie = cookies.first(where: { $0.name == "sessionKey" && $0.domain.contains("claude.ai") }) {
                    self.fired = true
                    self.onCapture(cookie.value)
                }
            }
        }
    }
}
#endif
