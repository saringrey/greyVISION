#if DEBUG
    import Foundation
    import OSLog

    /// Writes this process's own log lines to `Documents/gvlog.txt`, every
    /// few seconds, when launched with `--export-log`. Debug builds only.
    ///
    /// A physical device's unified log is not readable from the Mac without a
    /// sysdiagnose; a file in the app container is — `devicectl device copy
    /// from` pulls it. This is how ARKit, which the simulator cannot run, gets
    /// verified on a phone nobody is holding.
    enum GVLogExport {
        static func runIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("--export-log"),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let url = documents.appendingPathComponent("gvlog.txt")
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { continue }
                    let start = store.position(timeIntervalSinceLatestBoot: 0)
                    let lines = (try? store.getEntries(at: start))?
                        .compactMap { $0 as? OSLogEntryLog }
                        .filter { $0.subsystem == "com.saringrey.greyvision" || $0.subsystem.hasPrefix("com.apple.arkit") }
                        .map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.composedMessage)" }
                        ?? []
                    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }
#endif
