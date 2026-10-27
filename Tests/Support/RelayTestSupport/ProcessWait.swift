import Foundation

extension Process {
    /// Waits for the process to exit by polling `isRunning`. Unlike
    /// `waitUntilExit()` — which spins the run loop and, under heavy
    /// parallel test load, can miss the wakeup for a process that has
    /// already exited and been reaped — this always returns. A process
    /// still running at `timeout` is killed.
    public func waitForExit(timeout: Duration = .seconds(60)) {
        let deadline = ContinuousClock.now + timeout
        var killed = false
        while isRunning {
            if !killed, ContinuousClock.now >= deadline {
                killed = true
                kill(processIdentifier, SIGKILL)
            }
            usleep(5_000)
        }
    }
}
