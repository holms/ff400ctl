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

/// Watches a directory for write events and invokes `handler` after a
/// debounce interval — bursts (e.g. ffctl's atomic save + follow-up
/// writes) collapse into a single call. Atomic saves replace files, so
/// the DIRECTORY is watched, not the file.
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    public init?(directory: URL, debounce: TimeInterval = 0.2,
                 queue: DispatchQueue = .main,
                 handler: @escaping () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: queue)
        var scheduled = false
        src.setEventHandler {
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + debounce) {
                scheduled = false
                handler()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
