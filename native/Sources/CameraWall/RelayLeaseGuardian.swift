import Darwin
import Foundation

/// This process owns exactly one direct child and holds the inherited runtime
/// lease until waitpid has reaped that child. It never signals a foreign PID.
enum RelayLeaseGuardian {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 5, let parent = Int32(arguments[2]), parent > 1,
              getppid() == parent else { return 1 }
        var metadata = stat()
        guard fstat(STDIN_FILENO, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0 else { return 1 }
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
        signal(SIGCHLD, SIG_DFL)
        let queue = kqueue()
        guard queue >= 0 else { return 1 }
        defer { close(queue) }
        var registrations = [
            kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC),
                   flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                   fflags: UInt32(NOTE_EXIT), data: 0, udata: nil),
            kevent(ident: UInt(SIGTERM), filter: Int16(EVFILT_SIGNAL),
                   flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil),
            kevent(ident: UInt(SIGINT), filter: Int16(EVFILT_SIGNAL),
                   flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil)
        ]
        guard kevent(queue, &registrations, Int32(registrations.count), nil, 0, nil) == 0,
              getppid() == parent else { return 1 }
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        var ready: UInt8 = 0x52
        guard write(STDOUT_FILENO, &ready, 1) == 1 else { return 1 }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return 1 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 else {
            return 1
        }
        guard posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            return 1
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return 1 }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGCHLD)
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF)) == 0 else { return 1 }
        let values = [arguments[3], "-config", arguments[4]].map { strdup($0) }
        defer { for value in values { free(value) } }
        guard values.allSatisfy({ $0 != nil }) else { return 1 }
        var argv = values + [nil]
        var child: pid_t = 0
        let spawned = arguments[3].withCString {
            posix_spawn(&child, $0, &actions, &attributes, &argv, environ)
        }
        guard spawned == 0, child > 0 else { return 1 }
        var signalled = false
        while true {
            var status: Int32 = 0
            let result = waitpid(child, &status, WNOHANG)
            if result == child { return 0 }
            if result < 0 && errno != EINTR {
                // An unprovable child state must not release the runtime lease.
                while true { sleep(3600) }
            }
            var event = kevent()
            var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
            let events = kevent(queue, nil, 0, &event, 1, &timeout)
            if !signalled && (events > 0 || (events < 0 && errno != EINTR)) {
                // The unreaped direct child still owns this PID, even if it
                // exits between waitpid(WNOHANG) and kill().
                _ = kill(child, SIGTERM)
                signalled = true
            }
        }
    }
}
