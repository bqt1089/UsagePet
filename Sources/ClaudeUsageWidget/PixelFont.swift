#if os(macOS)
import SwiftUI
import CoreText

/// Registers the bundled Silkscreen TTFs (Resources/Fonts) with the system
/// font manager at launch, and vends a `Font` for pixel-pet UI that falls
/// back to the system monospaced font if registration or lookup fails for
/// any reason (missing bundle resource, registration error, sandboxing,
/// etc). Safe to call `register()` more than once.
enum PixelFont {

    private static let familyName = "Silkscreen"
    private(set) static var isAvailable = false
    private static var didRegister = false

    /// Attempts to register every `.ttf` in the app bundle's flattened
    /// `Resources` (see Package.swift's `.process("Resources")`) with
    /// `CTFontManagerRegisterFontsForURL`. Never throws; failures just mean
    /// `isAvailable` stays false and callers fall back to system fonts.
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        guard let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil), !urls.isEmpty else {
            return
        }

        var registeredAny = false
        for url in urls {
            var errorRef: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
            if ok {
                registeredAny = true
            }
            // errorRef, if present, is intentionally discarded — registration
            // failure (e.g. already registered) is non-fatal.
        }
        isAvailable = registeredAny
    }

    /// A Silkscreen font at `size`, falling back to `.system(.monospaced)`
    /// when the bundled font isn't available.
    static func font(size: CGFloat, bold: Bool) -> Font {
        guard isAvailable else {
            return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced)
        }
        return .custom(bold ? "Silkscreen-Bold" : "Silkscreen", size: size)
    }
}

#endif
