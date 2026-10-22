import Foundation

/// Serializes hardware writes on one background queue and drops
/// superseded work: while a write is in flight, a new submission for the
/// same key replaces the pending one. A fast fader drag therefore
/// coalesces into ~1 write per transaction time instead of queueing a
/// backlog that blocks the main thread.
public final class WriteCoalescer {
    private let q = DispatchQueue(label: "ff400.hw", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [(key: String, work: () -> Void)] = []
    private var scheduled = false

    public init() {}

    public func submit(_ key: String, _ work: @escaping () -> Void) {
        lock.lock()
        if let i = pending.firstIndex(where: { $0.key == key }) {
            pending[i].work = work
        } else {
            pending.append((key, work))
        }
        if !scheduled {
            scheduled = true
            q.async { self.drainLoop() }
        }
        lock.unlock()
    }

    private func drainLoop() {
        while true {
            lock.lock()
            if pending.isEmpty {
                scheduled = false
                lock.unlock()
                return
            }
            let next = pending.removeFirst()
            lock.unlock()
            next.work()
        }
    }

    /// Block until every submitted job has run to completion. The queue is
    /// serial, so a sentinel block only runs after all work enqueued before
    /// it; loop because a racing submit can enqueue a new drain after it.
    public func waitUntilIdle() {
        while true {
            lock.lock()
            let idle = !scheduled && pending.isEmpty
            lock.unlock()
            if idle { return }
            let done = DispatchSemaphore(value: 0)
            q.async { done.signal() }
            done.wait()
        }
    }
}
