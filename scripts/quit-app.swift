// Quits running copies of the app the normal way (like ⌘Q), so it saves its sessions, and waits for them to exit.
import AppKit

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.artemfritzsch.Patchbay")
apps.forEach { $0.terminate() }
let deadline = Date().addingTimeInterval(60)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
if apps.contains(where: { !$0.isTerminated }) {
    print("Patchbay is still running (a quit confirmation may be waiting). Quit it, then run this again.")
    exit(1)
}
