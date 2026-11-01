import AppKit
import Foundation

/// Brea's version as people read it, built from the app bundle's Info.plist.
///
/// | Key | Source (`Config/Version.xcconfig`) | Example |
/// |---|---|---|
/// | `CFBundleShortVersionString` | `MARKETING_VERSION` | `0.1.0` |
/// | `BreaVersionLabel` | `BREA_VERSION_LABEL` (empty for a final release) | `alpha.1` |
/// | `CFBundleVersion` | `CURRENT_PROJECT_VERSION` | `1` |
///
/// ``display`` joins the first two Semantic Versioning style (`0.1.0-alpha.1`); macOS only
/// accepts numbers in `CFBundleShortVersionString`, hence the separate label key.
public enum BreaVersion {
    public static var marketing: String { string(for: "CFBundleShortVersionString") ?? "0.0.0" }
    public static var label: String { string(for: "BreaVersionLabel") ?? "" }
    public static var build: String { string(for: "CFBundleVersion") ?? "0" }

    /// `0.1.0-alpha.1`, or `0.1.0` without a label.
    public static var display: String { label.isEmpty ? marketing : "\(marketing)-\(label)" }

    /// The standard About panel, showing ``display`` and the build number.
    @MainActor
    public static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: display, .version: build])
        NSApp.activate()
    }

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}
