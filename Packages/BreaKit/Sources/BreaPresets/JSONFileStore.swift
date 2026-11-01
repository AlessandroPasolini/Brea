import Foundation

/// Persists one `Codable` value as versioned JSON.
///
/// ## File
/// `{ "version": 1, "value": … }`, pretty-printed with sorted keys and written atomically.
/// Bump ``currentVersion`` when the stored shape changes and migrate in ``load()``.
///
/// ## Saving
/// 1. ``save(_:)`` keeps the value and (re)starts a debounce timer, because a slider drag
///    produces dozens of changes per second.
/// 2. When the timer fires, ``flush()`` writes the latest value.
/// 3. A failed write keeps the value, so the next save or flush retries it.
///
/// Call ``flush()`` before the app quits.
@MainActor
public final class JSONFileStore<Value: Codable & Sendable> {
    public static var currentVersion: Int { 1 }

    public let url: URL
    private let debounce: Duration
    private var pendingValue: Value?
    private var pendingWrite: Task<Void, Never>?

    public init(url: URL, debounce: Duration = .milliseconds(400)) {
        self.url = url
        self.debounce = debounce
    }

    /// `~/Library/Application Support/Brea/<fileName>`.
    public static func applicationSupport(_ fileName: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Brea", directoryHint: .isDirectory).appending(path: fileName)
    }

    /// The stored value, or `nil` when there is no file yet.
    ///
    /// An unreadable file is moved aside to `<name>.corrupt` instead of being overwritten later,
    /// so user data is never lost silently.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).value
        } catch {
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    public func save(_ value: Value) {
        pendingValue = value
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes any pending value now.
    public func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let value = pendingValue else { return }
        pendingValue = nil
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Envelope(version: Self.currentVersion, value: value)).write(to: url, options: .atomic)
        } catch {
            pendingValue = value
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let value: Value
    }
}
