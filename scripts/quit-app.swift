// Quits running copies of the installed app the normal way (like ⌘Q), so it saves its sessions, and waits for them to exit.
// The bundle ID comes from the installed app, which may still have an older ID than the one build.sh writes.
import AppKit

let installed = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Patchbay.app")
guard let id = Bundle(url: installed)?.bundleIdentifier else { exit(0) }  // nothing installed yet
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id)
apps.forEach { $0.terminate() }
let deadline = Date().addingTimeInterval(60)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
if apps.contains(where: { !$0.isTerminated }) {
    print("Patchbay is still running (a quit confirmation may be waiting). Quit it, then run this again.")
    exit(1)
}
