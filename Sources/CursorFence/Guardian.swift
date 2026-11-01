import CoreGraphics
import Darwin
import Foundation

/// Insurance for exits that run none of our code (`kill -9`, a crash): a
/// child process that waits for the app to die and then re-associates the
/// mouse. Harmless if the window server already did so.
enum Guardian {
    static let flag = "--guardian"

    /// Spawns `CursorFence --guardian <our pid>`.
    static func spawn() {
        guard let exe = Bundle.main.executablePath else { return }
        let argv = [exe, flag, String(getpid())]
        var cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, nil, &cargs, environ)
        if rc != 0 { log.error("guardian spawn failed: \(rc)") }
    }

    /// The guardian's whole life: block until `parent` exits, then let go.
    static func run(parent: pid_t) -> Never {
        let kq = kqueue()
        var ev = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                        fflags: NOTE_EXIT, data: 0, udata: nil)
        // If registering fails the parent is already gone.
        if kevent(kq, &ev, 1, nil, 0, nil) == 0 {
            var out = kevent()
            while kevent(kq, nil, 0, &out, 1, nil) < 0 && errno == EINTR {}
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
}

/// Last-ditch handlers inside the app itself. SIGTERM/SIGINT/SIGHUP quit
/// cleanly through the run loop; crash signals re-associate and re-raise.
enum ExitHandlers {
    nonisolated(unsafe) static var sources: [DispatchSourceSignal] = []

    static func install(onQuit: @escaping @Sendable () -> Void) {
        atexit { CGAssociateMouseAndMouseCursorPosition(1) }
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: onQuit)
            s.resume()
            sources.append(s)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                CGAssociateMouseAndMouseCursorPosition(1)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
