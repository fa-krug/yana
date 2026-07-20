import Foundation

/// A minimal async counting semaphore. `acquire()` suspends the calling task until a slot is free;
/// `release()` is synchronous so it can run from a `defer`. Waiters are woken FIFO.
///
/// Used to bound how many expensive operations (e.g. reader image decodes) run at once, so a burst
/// of concurrent work can't spike memory all at the same instant.
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = max(1, limit) }

    /// Suspends until a slot is available, then takes it. Pair with exactly one `release()`.
    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if available > 0 {
                available -= 1
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Returns a slot, waking the oldest waiter if any. Synchronous so it is `defer`-safe.
    func release() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let continuation = waiters.removeFirst()
            lock.unlock()
            continuation.resume()
        }
    }
}
