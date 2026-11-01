/// Which applications the equalizer processes.
///
/// ## Overview
/// The two modes are mutually exclusive and are chosen in Settings ▸ Audio:
/// - ``global``: one processing chain taps everything the system plays (except Brea itself).
/// - ``perApp``: one chain per selected application. Every chain uses the same settings, the
///   ones edited in the main window.
public enum EngineMode: String, Codable, CaseIterable, Sendable {
    /// One chain per selected application.
    case perApp
    /// A single chain for all system audio. The default.
    case global
}

/// Identifies a processing chain (its settings, meters and analyzer) independently of the
/// Core Audio objects that implement it, so the identity survives rebuilds of those objects.
public enum SessionKey: Hashable, Codable, Sendable {
    /// The system-wide chain, and the settings the editor shows.
    case global
    /// The chain of one application, identified by its bundle identifier.
    case app(bundleID: String)
}
