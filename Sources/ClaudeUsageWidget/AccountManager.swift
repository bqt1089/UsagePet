#if os(macOS)
import Foundation
import Observation
import Security
import ClaudeUsageCore

/// How the widget is authorized to read Claude usage data. Persisted in
/// UserDefaults under "accountMode"; nothing is read from Keychain or the
/// network until the user explicitly picks `.claudeCode` or `.manualToken`.
enum AccountMode: String, Equatable {
    case notLinked
    case claudeCode
    case manualToken
    case claudeWeb
}

/// Best-effort, non-fatal account details surfaced in the UI. Any field may
/// be nil if the source file is missing or doesn't have that key.
struct AccountInfo: Equatable {
    var email: String?
    var displayName: String?
    var organizationName: String?
    var subscriptionType: String?
}

/// A captured claude.ai web session: the `sessionKey` cookie plus whatever
/// we could best-effort resolve at sign-in time. Stored as JSON in this
/// app's own Keychain item (see `AppKeychain.saveWebSession`); never
/// logged or printed.
struct ClaudeWebSession: Codable, Equatable {
    var sessionKey: String
    var orgId: String?
    var orgName: String?
    var email: String?
    var displayName: String?
    var userAgent: String?
}

/// Stores the user-pasted OAuth token in the app's own Keychain item, never
/// the Claude Code one. The token is never logged or printed.
enum AppKeychain {
    static let service = "io.github.bqt1089.UsagePet"
    static let account = "oauth-token"
    static let webSessionAccount = "claude-web-session"

    static func save(token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        return saveData(data, account: account)
    }

    static func load() -> String? {
        guard let data = loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
        deleteData(account: account)
    }

    /// Saves a captured claude.ai web session as a small JSON blob under a
    /// separate Keychain item, distinct from the OAuth-token item above.
    static func saveWebSession(_ session: ClaudeWebSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        return saveData(data, account: webSessionAccount)
    }

    static func loadWebSession() -> ClaudeWebSession? {
        guard let data = loadData(account: webSessionAccount) else { return nil }
        return try? JSONDecoder().decode(ClaudeWebSession.self, from: data)
    }

    @discardableResult
    static func deleteWebSession() -> Bool {
        deleteData(account: webSessionAccount)
    }

    private static func saveData(_ data: Data, account: String) -> Bool {
        _ = deleteData(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    @discardableResult
    private static func deleteData(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Explicit, consent-based Claude account linking. Nothing here touches the
/// Claude Code Keychain item or the network until the user picks a mode.
@MainActor
@Observable
final class AccountManager {
    private(set) var mode: AccountMode
    private(set) var accountInfo: AccountInfo?

    private static let modeKey = "accountMode"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? AccountMode.notLinked.rawValue
        mode = AccountMode(rawValue: raw) ?? .notLinked
        accountInfo = Self.readAccountInfo(mode: mode)
    }

    func useClaudeCodeLogin() {
        #if os(macOS)
        ClaudeCodeTokenProvider.interactiveUntil = Date().addingTimeInterval(120)
        #endif
        setMode(.claudeCode)
    }

    /// Saves the pasted token to the app's own Keychain item and switches to
    /// manual-token mode. Returns false (and leaves the previous mode intact)
    /// if the token is blank or the Keychain write fails.
    @discardableResult
    func saveManualToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, AppKeychain.save(token: trimmed) else { return false }
        setMode(.manualToken)
        return true
    }

    /// Clears everything: mode, this app's own Keychain item(s), and any
    /// cached account info the caller is holding.
    func unlink() {
        AppKeychain.delete()
        AppKeychain.deleteWebSession()
        accountInfo = nil
        setMode(.notLinked)
    }

    /// Called by `ClaudeWebLoginWindow` once a captured session has been
    /// verified (org discovery + a first usage fetch both succeeded).
    /// Saves it to this app's Keychain and switches to `.claudeWeb`.
    @discardableResult
    func linkClaudeWebSession(_ session: ClaudeWebSession) -> Bool {
        guard AppKeychain.saveWebSession(session) else { return false }
        setMode(.claudeWeb)
        return true
    }

    /// Builds the right usage fetcher for the current mode, or nil for
    /// `.notLinked` (meaning: don't poll at all) or a `.claudeWeb` mode
    /// whose Keychain item is somehow missing.
    func makeUsageFetcher() -> (any UsageFetching)? {
        switch mode {
        case .notLinked:
            return nil
        case .claudeCode:
            return UsageClient(tokenProvider: ClaudeCodeTokenProvider())
        case .manualToken:
            return UsageClient(tokenProvider: StaticTokenProvider { AppKeychain.load() })
        case .claudeWeb:
            guard let session = AppKeychain.loadWebSession() else { return nil }
            return ClaudeWebUsageClient(sessionKey: session.sessionKey, orgId: session.orgId, userAgent: session.userAgent)
        }
    }

    func refreshAccountInfo() {
        accountInfo = Self.readAccountInfo(mode: mode)
    }

    private func setMode(_ newMode: AccountMode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        refreshAccountInfo()
        NotificationCenter.default.post(name: .usageAccountModeChanged, object: nil)
    }

    /// Dispatches to the right account-info source for `mode`. Never
    /// throws; missing/unreadable sources just mean no info is shown.
    private static func readAccountInfo(mode: AccountMode) -> AccountInfo? {
        switch mode {
        case .notLinked:
            return nil
        case .claudeCode, .manualToken:
            return readClaudeCodeAccountInfo()
        case .claudeWeb:
            return readClaudeWebAccountInfo()
        }
    }

    /// Best-effort info for a linked claude.ai web session, read from this
    /// app's own Keychain item (never the network).
    private static func readClaudeWebAccountInfo() -> AccountInfo? {
        guard let session = AppKeychain.loadWebSession() else { return nil }
        var info = AccountInfo()
        info.email = session.email
        info.displayName = session.displayName
        info.organizationName = session.orgName
        return info
    }

    /// Reads `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) for
    /// `oauthAccount`, and best-effort the credentials file for
    /// `subscriptionType`. Never throws; missing/unreadable files just mean
    /// no info is shown.
    private static func readClaudeCodeAccountInfo() -> AccountInfo? {
        let fileManager = FileManager.default
        let configDir: URL
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            configDir = URL(fileURLWithPath: dir)
        } else {
            configDir = fileManager.homeDirectoryForCurrentUser
        }

        let claudeJSONURL = configDir.appendingPathComponent(".claude.json")
        guard
            let data = try? Data(contentsOf: claudeJSONURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauthAccount = root["oauthAccount"] as? [String: Any]
        else {
            return nil
        }

        var info = AccountInfo()
        info.email = oauthAccount["emailAddress"] as? String
        info.displayName = oauthAccount["displayName"] as? String
        info.organizationName = oauthAccount["organizationName"] as? String
        info.subscriptionType = readSubscriptionType()
        return info
    }


    /// Non-invasive best-effort check for the Settings "Recommended" badge:
    /// true when there's something that looks like a Claude Code login
    /// (env token, or a readable credentials file) without touching the
    /// macOS Keychain (which could pop an access prompt just from this
    /// check).
    static func claudeCodeCredentialSeemsPresent() -> Bool {
        if let envToken = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !envToken.isEmpty {
            return true
        }
        let fileManager = FileManager.default
        let credentialsURL: URL
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            credentialsURL = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        } else {
            credentialsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        }
        return fileManager.fileExists(atPath: credentialsURL.path)
    }

    /// True when Claude Code's credentials file exists and has a
    /// `claudeAiOauth` access token, but no `subscriptionType` — the shape
    /// left by an API-key `claude /login`, which has no usage endpoint of
    /// its own. Best-effort; never throws.
    static func claudeCodeCredentialsLackSubscription() -> Bool {
        let fileManager = FileManager.default
        let credentialsURL: URL
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            credentialsURL = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        } else {
            credentialsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        }
        guard
            let data = try? Data(contentsOf: credentialsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String,
            !accessToken.isEmpty
        else {
            return false
        }
        return oauth["subscriptionType"] == nil
    }

    private static func readSubscriptionType() -> String? {
        let fileManager = FileManager.default
        let credentialsURL: URL
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            credentialsURL = URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        } else {
            credentialsURL = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        }
        guard
            let data = try? Data(contentsOf: credentialsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            return nil
        }
        return oauth["subscriptionType"] as? String
    }
}

extension Notification.Name {
    static let usageAccountModeChanged = Notification.Name("usageAccountModeChanged")
    static let usageWidgetShowSettings = Notification.Name("usageWidgetShowSettings")
}

#endif
