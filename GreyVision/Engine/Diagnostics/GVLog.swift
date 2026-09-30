import OSLog

enum GVLog {
    private static let subsystem = "com.saringrey.greyvision"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let rendering = Logger(subsystem: subsystem, category: "rendering")
    static let recording = Logger(subsystem: subsystem, category: "recording")
    static let analysis = Logger(subsystem: subsystem, category: "analysis")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let performance = Logger(subsystem: subsystem, category: "performance")
}
