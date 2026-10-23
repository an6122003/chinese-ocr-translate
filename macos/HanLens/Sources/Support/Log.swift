import OSLog

/// Unified logging. Watch live with:
/// `log stream --predicate 'subsystem == "com.nguyenan.HanLens"' --level debug`
nonisolated enum Log {
    static let app = Logger(subsystem: "com.nguyenan.HanLens", category: "app")
    static let capture = Logger(subsystem: "com.nguyenan.HanLens", category: "capture")
    static let input = Logger(subsystem: "com.nguyenan.HanLens", category: "input")
    static let lookup = Logger(subsystem: "com.nguyenan.HanLens", category: "lookup")
}
