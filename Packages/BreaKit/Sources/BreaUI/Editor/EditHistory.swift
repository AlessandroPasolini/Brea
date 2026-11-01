import BreaDSP
import Foundation

/// Undo and redo for the EQ, on the window's `UndoManager` (⌘Z and ⇧⌘Z in the Edit menu).
///
/// ## Model
/// Edits apply live while a gesture runs; only ``commit(_:actionName:undoManager:apply:)``
/// creates a step, so a whole drag is one action. The history keeps the last committed settings
/// as its baseline. Changes that only affect the view (scrolling, the analyzer point) never
/// commit.
///
/// ## Steps
/// 1. `commit` compares the current settings with the baseline; when they differ it registers an
///    undo that restores the baseline, then adopts the current settings as the new baseline.
/// 2. Undoing applies the stored settings, makes them the baseline and registers the inverse,
///    which the undo manager files as the redo step. Redo works the same way in reverse.
@MainActor
final class EditHistory {
    private var committed: ChainSettings?

    func commit(_ current: ChainSettings, actionName: String, undoManager: UndoManager?,
                apply: @escaping @MainActor (ChainSettings) -> Void) {
        defer { committed = current }
        guard let previous = committed, previous != current, let undoManager else { return }
        register(restoring: previous, replacing: current, actionName: actionName, undoManager: undoManager, apply: apply)
    }

    /// Adopts `settings` as the baseline without creating a step (first appearance, New, Open).
    func reset(to settings: ChainSettings) {
        committed = settings
    }

    private func register(restoring target: ChainSettings, replacing current: ChainSettings, actionName: String,
                          undoManager: UndoManager, apply: @escaping @MainActor (ChainSettings) -> Void) {
        undoManager.registerUndo(withTarget: self) { history in
            MainActor.assumeIsolated {
                apply(target)
                history.committed = target
                history.register(restoring: current, replacing: target, actionName: actionName,
                                 undoManager: undoManager, apply: apply)
            }
        }
        undoManager.setActionName(actionName)
    }
}
