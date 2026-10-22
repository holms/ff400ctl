import Foundation
import FFCore

/// Decides whether a state.json read from disk should replace the
/// tracked state. ffctl saves state after every change, and the tray
/// auto-saves its own changes — so a file event doesn't always mean an
/// external actor wrote it.
///
/// Rules (previously inline in MixerModel.reloadStateIfChanged):
/// - identical to the tracked state → nothing to do
/// - identical to `lastSaved` → our own autosave, skip
/// - DIFFERENT from `lastSaved` but the file is older than a queued save
///   → restoring it would rewind a live drag; the inequality against
///   `current` alone doesn't cover this, hence the `lastSaved` guard.
public enum ExternalStateWatcher {
    public static func shouldAdopt(file: MixerState, current: MixerState,
                                   lastSaved: MixerState?) -> Bool {
        file != current && file != lastSaved
    }
}
