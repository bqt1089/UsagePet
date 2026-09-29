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
}

/// Best-effort, non-fatal account details surfaced in the UI. Any field may
/// be nil if the source file is missing or doesn't have that key.
struct AccountInfo: Equatable {
    var email: String?
    var displayName: String?
    var organizationName: String?
    var subscriptionType: String?
}

/// Stores the user-pasted OAuth token in the app's own Keychain item, never
/// the Claude Code one. The token is never logged or printed.
enum AppKeychain {
    static let service = "io.github.bqt1089.UsagePet"
    static let account = "oauth-token"

    /// Account key of the pre-0.5.0 "Sign in with claude.ai" web session
    /// Keychain item. The feature is gone; this constant only exists so
    /// `deleteLegacyWebSession()` can clean up any leftover item.
    private static let legacyWebSessionAccount = "claude-web-session"

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

    /// Best-effort delete of the pre-0.5.0 "Sign in with claude.ai" session
    /// Keychain item, if one is still around. Safe to call even when no such
    /// item exists.
    @discardableResult
    static func deleteLegacyWebSession() -> Bool {
        deleteData(account: legacyWebSessionAccount)
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
        // MIGRATION: builds before 0.5.0 could persist "claudeWeb" (the
        // removed "Sign in with claude.ai" mode); treat that, or any other
        // unrecognized raw value, as not linked.
        mode = AccountMode(rawValue: raw) ?? .notLinked
        accountInfo = Self.readAccountInfo(mode: mode)
        // Best-effort cleanup of any session left behind by that removed
        // feature, regardless of the mode we ended up in.
        AppKeychain.deleteLegacyWebSession()
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
        AppKeychain.deleteLegacyWebSession()
        accountInfo = nil
        setMode(.notLinked)
    }

    /// Builds the right usage fetcher for the current mode, or nil for
    /// `.notLinked` (meaning: don't poll at all).
    func makeUsageFetcher() -> (any UsageFetching)? {
        switch mode {
        case .notLinked:
            return nil
        case .claudeCode:
            return UsageClient(tokenProvider: ClaudeCodeTokenProvider())
        case .manualToken:
            return UsageClient(tokenProvider: StaticTokenProvider { AppKeychain.load() })
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
        }
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
