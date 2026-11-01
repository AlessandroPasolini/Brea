import AppKit
import BreaAudioEngine
import BreaCore
import BreaPresets
import SwiftUI

/// The main window's content: the Parametric Equalizer board on Reloj's surface.
///
/// ## Responsibilities
/// - Mirrors the document onto the window: title (file name or "Untitled"), the edited mark
///   for unsaved changes and the proxy icon for the file.
/// - Applies the appearance chosen in Settings.
/// - Makes the window slightly translucent: the window's container background is a material,
///   which blurs what lies behind the window (like an `NSVisualEffectView` with
///   `.behindWindow` blending), and Reloj's surface lies over it at ``surfaceOpacity``. The
///   material stays active when the window is not key, so the look does not change on focus.
/// - Reports engine problems (usually a missing Audio Capture permission) once per distinct
///   problem, with a button to the matching Privacy & Security pane. A problem that clears and
///   comes back is reported again.
public struct RootView: View {
    public static let size = CGSize(width: Reloj.Size.canvasWide, height: EQEditorView.boardHeight)
    /// How much of Reloj's surface covers the blurred desktop; lower is more transparent.
    static let surfaceOpacity = 0.82

    private static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")

    private let model: EditorModel
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system
    @State private var presentedProblem: String?
    @State private var acknowledgedProblem: String?

    public init(model: EditorModel) {
        self.model = model
    }

    public var body: some View {
        EQEditorView(model: model)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Reloj.Palette.surface.opacity(Self.surfaceOpacity))
            .containerBackground(Material.ultraThin.materialActiveAppearance(.active), for: .window)
            .navigationTitle(model.displayName)
            .background(WindowDocumentState(title: model.displayName, isEdited: model.isDirty, url: model.documentURL))
            .preferredColorScheme(appearance.colorScheme)
            .onChange(of: engineProblem, initial: true) { _, problem in
                if let problem, problem != acknowledgedProblem { presentedProblem = problem }
                if problem == nil { acknowledgedProblem = nil }
            }
            .alert("Brea can’t process audio", isPresented: problemBinding) {
                Button("Open Privacy Settings") {
                    if let url = Self.privacySettingsURL { NSWorkspace.shared.open(url) }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(presentedProblem ?? "")
            }
    }

    /// The first session error, or an engine-wide problem such as a missing output device.
    private var engineProblem: String? {
        let status = model.controller.status
        return status.errors.values.sorted().first ?? status.message
    }

    private var problemBinding: Binding<Bool> {
        Binding {
            presentedProblem != nil
        } set: { isPresented in
            if !isPresented {
                acknowledgedProblem = presentedProblem
                presentedProblem = nil
            }
        }
    }
}

/// Mirrors the document state onto the hosting `NSWindow`: title, edited mark and proxy icon.
/// The window is only reachable once the view is in it, hence the asynchronous update.
private struct WindowDocumentState: NSViewRepresentable {
    let title: String
    let isEdited: Bool
    let url: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.title = title
            window.isDocumentEdited = isEdited
            window.representedURL = url
        }
    }
}

#Preview(traits: .fixedLayout(width: 1_170, height: 558)) {
    let store = JSONFileStore<[EQPreset]>(url: FileManager.default.temporaryDirectory.appending(path: "BreaPreview-presets.json"))
    RootView(model: EditorModel(controller: AudioEngineController(configuration: EngineConfiguration(mode: .global)),
                                presets: PresetLibrary(store: store)))
}
