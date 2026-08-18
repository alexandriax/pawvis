import Darwin
import Foundation

/// A child process that is the leader of its own process group, so that
/// cancelling it can signal the whole tree it spawned — `kill(-pid, …)` —
/// not just the immediate child.
///
/// Foundation's `Process` cannot provide this. It exposes no posix_spawn
/// attribute hook, and re-grouping the child from the parent after `run()`
/// (`setpgid(pid, pid)`) is not a race to win but a guaranteed failure:
/// `Process` spawns via posix_spawn, so by the time `run()` returns the child
/// has already exec'd, and POSIX makes `setpgid` on an exec'd child EACCES —
/// measured here, errno 13 every time. So this wraps posix_spawn directly
/// with `POSIX_SPAWN_SETPGROUP`: the child is a group leader from birth, and
/// every ordinary descendant it spawns (shell commands, node workers)
/// inherits the group. A descendant that deliberately calls setsid()/setpgid()
/// escapes — nothing short of a kernel jail prevents that — but agent CLIs
/// and the commands they run don't daemonize themselves.
///
/// The surface mirrors the slice of `Process` the agent manager uses, so the
/// streaming/termination plumbing around it is unchanged: pipes for
/// stdout/stderr (stdin is always /dev/null), a termination handler invoked
/// off-main after the child is reaped, `isRunning`, and a `terminationStatus`
/// that is the exit code — or, `Process`-style, the signal number when the
/// child died to a signal.
final class GroupLeaderProcess {
    var executablePath = ""
    /// argv[1...]; argv[0] is `executablePath`.
    var arguments: [String] = []
    /// nil inherits the parent's environment.
    var environment: [String: String]?
    var currentDirectoryPath: String?
    var standardOutput: Pipe?
    var standardError: Pipe?
    /// Called once, off the main thread, after the child has been reaped.
    /// Assign before `run()`.
    var terminationHandler: (@Sendable (GroupLeaderProcess) -> Void)?

    private(set) var processIdentifier: pid_t = 0

    /// Guards the fields the reaper thread writes while other threads read.
    private let lock = NSLock()
    private var launched = false
    private var reaped = false
    private var status: Int32 = 0

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return launched && !reaped
    }

    /// Valid once the termination handler has fired; 0 before launch/exit.
    var terminationStatus: Int32 {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    func run() throws {
        precondition(processIdentifier == 0, "run() may only be called once")

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETPGROUP(0): the child leads a fresh group whose id is its own
        // pid. SETSIGDEF/SETSIGMASK: default dispositions, nothing blocked,
        // so SIGTERM terminates until the CLI installs its own handler.
        // CLOEXEC_DEFAULT: the child inherits only the descriptors wired up
        // in the file actions below (Foundation's own NSTask hygiene).
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
            POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if let out = standardOutput {
            posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        }
        if let err = standardError {
            posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
        }
        if let directory = currentDirectoryPath {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        let environmentDict = environment ?? ProcessInfo.processInfo.environment
        var envp: [UnsafeMutablePointer<CChar>?] = environmentDict.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)

        // Close the parent's copies of the write ends either way: EOF on the
        // read side must depend only on the child side closing.
        try? standardOutput?.fileHandleForWriting.close()
        try? standardError?.fileHandleForWriting.close()

        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(rc)),
            ])
        }

        processIdentifier = pid
        lock.lock()
        launched = true
        lock.unlock()

        // Reaper: a blocking waitpid on a dedicated thread is immune to the
        // attach-after-exit races of kqueue-based process sources, and there
        // is at most a handful of agent runs alive at once. The thread
        // retains self until the child is reaped.
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            var result = waitpid(pid, &raw, 0)
            while result == -1 && errno == EINTR {
                result = waitpid(pid, &raw, 0)
            }
            let code: Int32
            if result == pid {
                // WIFEXITED → exit code; else WTERMSIG (Process convention).
                code = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : raw & 0x7f
            } else {
                code = -1 // reaped elsewhere somehow; report failure, not success
            }
            lock.lock()
            status = code
            reaped = true
            lock.unlock()
            terminationHandler?(self)
            terminationHandler = nil
        }
    }

    /// Send a signal to the child's whole process group. If the group signal
    /// fails while the child is still unreaped, fall back to the single pid —
    /// the pre-group behavior is the floor, never the ceiling. After the reap
    /// the pid may already be reused, so nothing is signalled then (a group
    /// kill on a fully-exited group is ESRCH and harmless; group ids can't be
    /// recycled while any member survives).
    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        lock.lock()
        let pid = processIdentifier
        let unreaped = launched && !reaped
        lock.unlock()
        guard pid > 0 else { return false }
        if kill(-pid, signal) == 0 { return true }
        guard unreaped else { return false }
        return kill(pid, signal) == 0
    }
}
