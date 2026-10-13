import Foundation

/// FILEE_PROFILE=1 logs the time of each phase to stderr.
enum Profile {
    static let on = ProcessInfo.processInfo.environment["FILEE_PROFILE"] == "1"

    @discardableResult
    static func mark(_ label: String, _ since: TimeInterval) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        if on { FileHandle.standardError.write(Data("⏱ \(label): \(Int((now - since) * 1000)) ms\n".utf8)) }
        return now
    }

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
