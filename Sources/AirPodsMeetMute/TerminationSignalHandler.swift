import AppKit

/// SIGTERM (`kill`, logout, shutdown) bypasses `applicationWillTerminate` by default, which would
/// skip the unmute-on-quit. Route it through `NSApp.terminate` so that hook runs.
final class TerminationSignalHandler {
    private var source: DispatchSourceSignal?

    func install() {
        signal(SIGTERM, SIG_IGN)  // the dispatch source receives it instead of the default kill
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        source = termination
    }
}
