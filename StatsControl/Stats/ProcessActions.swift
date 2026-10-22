import AppKit
import Darwin

/// Only action: quit (normal or immediate).
@MainActor
enum ProcessActions {
    /// Processes the Mac cannot run without – never offered, even if they belong to the current user.
    static let protectedNames: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "SystemUIServer"]

    static func canKill(_ entry: ProcessEntry) -> Bool {
        entry.uid == getuid() && entry.pid > 1 && entry.pid != getpid() && !protectedNames.contains(entry.name)
            && entry.app?.bundleIdentifier != "com.apple.finder"
    }

    /// Quit immediately (SIGKILL). For apps also all helper processes that belong to them. Returns false if macOS refuses.
    @discardableResult
    static func forceQuit(_ entry: ProcessEntry) -> Bool {
        guard canKill(entry) else { return false }
        if let app = entry.app { _ = app.forceTerminate() }
        var ok = true
        for pid in entry.pids where pid > 1 && pid != getpid() {
            // Foreign helper processes (e.g. owned by root) are left alone; only whether the main process ends counts.
            if kill(pid, SIGKILL) != 0, errno != ESRCH, pid == entry.pid { ok = false }
        }
        return ok
    }

    /// Quit normally: apps may still save or ask, processes receive SIGTERM.
    @discardableResult
    static func quit(_ entry: ProcessEntry) -> Bool {
        guard canKill(entry) else { return false }
        if let app = entry.app { return app.terminate() }
        return kill(entry.pid, SIGTERM) == 0 || errno == ESRCH
    }
}
