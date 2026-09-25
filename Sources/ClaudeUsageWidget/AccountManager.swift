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

    static func save(token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        _ = delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
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
        accountInfo = Self.readAccountInfo()
    }

    func useClaudeCodeLogin() {
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

    /// Clears everything: mode, this app's own Keychain item, and any cached
    /// account info the caller is holding.
    func unlink() {
        AppKeychain.delete()
        accountInfo = nil
        setMode(.notLinked)
    }

    /// Builds the right token source for the current mode, or nil for
    /// `.notLinked` (meaning: don't poll at all).
    func makeTokenProvider() -> TokenProvider? {
        switch mode {
        case .notLinked:
            return nil
        case .claudeCode:
            return ClaudeCodeTokenProvider()
        case .manualToken:
            return StaticTokenProvider { AppKeychain.load() }
        }
    }

    func refreshAccountInfo() {
        accountInfo = Self.readAccountInfo()
    }

    private func setMode(_ newMode: AccountMode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
        refreshAccountInfo()
        NotificationCenter.default.post(name: .usageAccountModeChanged, object: nil)
    }

    /// Reads `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json`) for
    /// `oauthAccount`, and best-effort the credentials file for
    /// `subscriptionType`. Never throws; missing/unreadable files just mean
    /// no info is shown.
    private static func readAccountInfo() -> AccountInfo? {
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
