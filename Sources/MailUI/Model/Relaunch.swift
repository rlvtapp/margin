#if os(macOS)
import AppKit
import Foundation

/// Restarting Margin: this copy quits first, and only then is Margin opened again, so there is
/// never a second copy beside the first (a second window, a second Dock icon).
public enum Relaunch {
    /// How long the helper waits for this copy to quit before giving up. A quit that was
    /// stopped must not reopen Margin much later, at some unrelated moment.
    static let patience = 60

    /// A small shell that waits for `pid` to exit, then runs `opener` on `bundle`. It
    /// outlives Margin, which is what lets it reopen Margin once Margin is gone.
    static func helper(waitingFor pid: Int32, reopening bundle: String, opener: String = "/usr/bin/open") -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Ten checks a second, at most `patience` seconds; nothing opens if it is still running.
        let script = """
        n=0; while /bin/kill -0 "$1" 2>/dev/null; do n=$((n+1)); [ "$n" -gt \(patience * 10) ] && exit 1; /bin/sleep 0.1; done; "$2" "$3"
        """
        process.arguments = ["-c", script, "relaunch", String(pid), opener, bundle]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Quits Margin and opens it again once it has quit. If the helper can't start, Margin
    /// stays open rather than quitting with nothing to bring it back.
    @MainActor public static func now() {
        let helper = helper(waitingFor: ProcessInfo.processInfo.processIdentifier, reopening: Bundle.main.bundlePath)
        do {
            try helper.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    /// Runs `work` and then calls `done`, once: when the work finishes or after `limit`,
    /// whichever is first. Work that never finishes (a server that doesn't answer) can't hold
    /// up quitting.
    @MainActor public static func finish(_ work: @escaping @MainActor () async -> Void, atMost limit: Duration, then done: @escaping @MainActor () -> Void) {
        let once = Once(done)
        Task { @MainActor in
            await work()
            once.call()
        }
        Task { @MainActor in
            try? await Task.sleep(for: limit)
            once.call()
        }
    }

    @MainActor private final class Once {
        private var action: (@MainActor () -> Void)?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func call() {
            let action = action
            self.action = nil
            action?()
        }
    }
}
#endif
