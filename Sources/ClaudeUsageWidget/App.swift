// The full menu-bar app requires AppKit + SwiftUI, which only exist on
// macOS. Everything below is compiled only there; on other platforms (e.g.
// running `swift test` for ClaudeUsageCore in CI on Linux) this file
// contributes a trivial stub entry point instead, so the package as a whole
// still resolves and builds.
#if os(macOS)
import SwiftUI
import AppKit
import ServiceManagement
import ClaudeUsageCore

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContents()
                .environment(appDelegate.store)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.store)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}

@MainActor
struct SettingsView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.5
    @AppStorage("widgetScale") private var widgetScale = WidgetScale.default
    @AppStorage("theme") private var theme = WidgetTheme.pixel.rawValue
    @State private var showDebugMoodPin = false

    var body: some View {
        Form {
            Section("Account") {
                AccountSection()
            }

            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Pixel Pet").tag(WidgetTheme.pixel.rawValue)
                    Text("Classic").tag(WidgetTheme.classic.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                LabeledContent("Widget size") {
                    HStack {
                        Text("\(Int(WidgetScale.min * 100))%").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $widgetScale, in: WidgetScale.min...WidgetScale.max, step: 0.05)
                            .frame(width: 140)
                        Text("\(Int(WidgetScale.max * 100))%").font(.caption).foregroundStyle(.secondary)
                        Text("\(Int((widgetScale * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                        Button("Reset") { widgetScale = WidgetScale.default }
                            .controlSize(.small)
                    }
                }
                LabeledContent("Background opacity") {
                    HStack {
                        Slider(value: $backgroundOpacity, in: 0...1, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int((backgroundOpacity * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                if theme == WidgetTheme.pixel.rawValue {
                    DisclosureGroup("Debug: pin a mood preview", isExpanded: $showDebugMoodPin) {
                        MoodPinPicker()
                    }
                }
            }

            Section("General") {
                LaunchAtLoginToggle()
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Backing values for the Appearance > Theme picker, persisted as a plain
/// String in `@AppStorage("theme")` so it's trivial to read from any view.
enum WidgetTheme: String {
    case pixel
    case classic
}

/// Settings-only debug control: forces `UsageStore.currentMood` to a fixed
/// value, bypassing `MoodEngine` entirely, so the Pixel Pet look can be
/// reviewed for every mood without needing to reproduce each usage state
/// live. "Auto" (the default) restores normal mood-engine behavior.
@MainActor
private struct MoodPinPicker: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        Picker("Pinned mood", selection: Binding(
            get: { store.debugPinnedMood },
            set: { store.debugPinnedMood = $0 }
        )) {
            Text("Auto (off)").tag(PetMood?.none)
            ForEach(PetMood.allCases, id: \.self) { mood in
                Text(mood.rawValue.capitalized).tag(PetMood?.some(mood))
            }
        }
        .frame(width: 260)
    }
}

/// "Account" section of Settings: link status, linking actions, and the
/// advanced manual-token flow. Never touches Keychain or the network until
/// the user taps one of these buttons.
@MainActor
private struct AccountSection: View {
    @Environment(UsageStore.self) private var store
    @State private var showAdvanced = false
    @State private var tokenInput = ""
    @State private var caption: String?

    private var accountManager: AccountManager { store.accountManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine

            HStack(spacing: 10) {
                Button("Use Claude Code login") {
                    accountManager.useClaudeCodeLogin()
                    caption = "If macOS asks for Keychain access, allow it to read the Claude Code login."
                }
                Button("Sign in to Claude Code…") { openTerminalLogin() }
                Button("Unlink") { accountManager.unlink() }
                    .disabled(accountManager.mode == .notLinked)
            }

            DisclosureGroup("Advanced: paste token", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField("Paste access token", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                    HStack {
                        Button("Save") {
                            if accountManager.saveManualToken(tokenInput) {
                                tokenInput = ""
                                showAdvanced = false
                                caption = "Token saved to this app's Keychain item."
                            } else {
                                caption = "Couldn't save that token."
                            }
                        }
                        .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("Generate with `claude setup-token`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch accountManager.mode {
        case .notLinked:
            Text("Not linked").font(.headline)
        case .claudeCode, .manualToken:
            if let info = accountManager.accountInfo, let email = info.email {
                let plan = info.subscriptionType.map { " · \($0)" } ?? ""
                Text("Linked: \(email)\(plan)").font(.headline)
            } else {
                Text("Linked").font(.headline)
            }
        }
    }

    private func openTerminalLogin() {
        let source = "tell application \"Terminal\" to do script \"claude /login\""
        if let script = NSAppleScript(source: source) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            if errorDict != nil {
                caption = "Run `claude` then `/login` in Terminal."
            } else {
                caption = "Opened Terminal. After you finish logging in there, click \"Use Claude Code login\" above."
            }
        } else {
            caption = "Run `claude` then `/login` in Terminal."
        }
    }
}

/// "Launch at Login" toggle backed by `SMAppService`. Only works when
/// running the installed .app bundle (not `swift run`), since that's the
/// only way macOS has a stable bundle identifier/path to register.
@MainActor
private struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    private var unavailable: Bool { Bundle.main.bundleIdentifier == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at Login", isOn: Binding(
                get: { isEnabled },
                set: { toggle($0) }
            ))
            .disabled(unavailable)

            if unavailable {
                Text("Available when running the installed app.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func toggle(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enable
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Small helper view so the label can read live state from the store without
/// forcing the whole `MenuBarExtra` closure to re-evaluate more than needed.
@MainActor
private struct MenuBarLabel: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        let percentText = store.snapshot?.session.map { Formatting.percent($0.fraction) } ?? "--%"
        Label {
            Text(percentText)
        } icon: {
            Image(systemName: "gauge.with.dots.needle.33percent")
        }
    }
}

@MainActor
private struct MenuBarContents: View {
    @Environment(UsageStore.self) private var store
    @AppStorage("widgetVisible") private var widgetVisible = true
    @AppStorage("miniMode") private var miniMode = false

    var body: some View {
        accountRow

        Divider()

        Button(widgetVisible ? "Hide Widget" : "Show Widget") {
            widgetVisible.toggle()
            NotificationCenter.default.post(name: .usageWidgetVisibilityChanged, object: nil)
        }

        Toggle("Mini Mode", isOn: $miniMode)

        Button("Reset Widget Position") {
            UserDefaults.standard.set(true, forKey: "widgetVisible")
            widgetVisible = true
            NotificationCenter.default.post(name: .usageWidgetResetPosition, object: nil)
        }

        Button("Refresh Now") {
            Task { await store.refresh(force: true) }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var accountRow: some View {
        switch store.accountManager.mode {
        case .notLinked:
            SettingsLink {
                Text("Not linked — Open Settings")
            }
        case .claudeCode, .manualToken:
            if let email = store.accountManager.accountInfo?.email {
                Text("Linked: \(email)")
            } else {
                Text("Linked")
            }
        }
    }
}

extension Notification.Name {
    static let usageWidgetVisibilityChanged = Notification.Name("usageWidgetVisibilityChanged")
    static let usageWidgetResetPosition = Notification.Name("usageWidgetResetPosition")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let accountManager = AccountManager()
    lazy var store = UsageStore(accountManager: accountManager)
    private var panel: WidgetPanel?
    private var showSettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        PixelFont.register()

        let panel = WidgetPanel(store: store)
        self.panel = panel

        let visible = UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true
        if visible {
            panel.orderFrontRegardless()
        }

        NotificationCenter.default.addObserver(
            forName: .usageWidgetVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let isVisible = UserDefaults.standard.object(forKey: "widgetVisible") as? Bool ?? true
                if isVisible {
                    panel.orderFrontRegardless()
                } else {
                    panel.orderOut(nil)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .usageWidgetResetPosition,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.resetPosition() }
        }

        showSettingsObserver = NotificationCenter.default.addObserver(
            forName: .usageWidgetShowSettings,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }

        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

#else

@main
struct ClaudeUsageWidgetUnsupportedPlatformStub {
    static func main() {
        print("ClaudeUsageWidget requires macOS 14+ (AppKit/SwiftUI).")
    }
}

#endif
