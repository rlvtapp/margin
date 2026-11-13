import Foundation
import Observation

/// A value worked out from the model and kept until something it was worked out from changes.
///
/// Views ask for the same lists many times in one redraw (the merged inbox, what's on screen,
/// the open conversation), and each used to be built from scratch every time: merge every
/// mailbox, sort, filter. With a few hundred conversations that's a few milliseconds a go; with
/// tens of thousands it's the whole frame, several times over.
///
/// The work is done inside Observation's own tracking, so "what it was worked out from" is
/// exactly what was read while working it out, the same way SwiftUI knows when to redraw a
/// view. When any of that is about to change, the kept value is dropped and `stamp` moves, and
/// since every reader reads `stamp`, views that showed the old value are redrawn.
@MainActor @Observable
final class Derived<Value> {
    private var stamp = 0
    @ObservationIgnored private var kept: Value?
    /// Counts how often the value was really worked out (for tests).
    @ObservationIgnored private(set) var computations = 0

    nonisolated init() {}

    func value(_ compute: () -> Value) -> Value {
        _ = stamp
        if let kept { return kept }
        computations += 1
        let fresh = withObservationTracking(compute) { [weak self] in
            // Called as one of the things read is about to change, on the thread changing it:
            // the main one for this model. Anything else waits its turn there.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.drop() }
            } else {
                Task { @MainActor in self?.drop() }
            }
        }
        kept = fresh
        return fresh
    }

    private func drop() {
        guard kept != nil else { return }
        kept = nil
        stamp &+= 1
    }
}

/// Like `Derived`, for a family of values that depend on a key (the unread count of each
/// mailbox, say): all of them are dropped together when anything they read changes.
@MainActor @Observable
final class DerivedByKey<Key: Hashable, Value> {
    private var stamp = 0
    @ObservationIgnored private var kept: [Key: Value] = [:]
    @ObservationIgnored private var isTracking = false

    nonisolated init() {}

    func value(for key: Key, _ compute: () -> Value) -> Value {
        _ = stamp
        if let known = kept[key] { return known }
        let fresh = withObservationTracking(compute) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.drop() }
            } else {
                Task { @MainActor in self?.drop() }
            }
        }
        kept[key] = fresh
        return fresh
    }

    private func drop() {
        guard !kept.isEmpty else { return }
        kept = [:]
        stamp &+= 1
    }
}
