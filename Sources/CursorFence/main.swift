import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == Guardian.flag, let parent = pid_t(arguments[2]) {
    Guardian.run(parent: parent)
}

// Start every launch from a known state: the mouse drives the cursor.
CGAssociateMouseAndMouseCursorPosition(1)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    ExitHandlers.install {
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    app.run()
}
